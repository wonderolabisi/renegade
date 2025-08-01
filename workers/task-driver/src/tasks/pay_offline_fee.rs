//! The `PayOfflineFee` task is responsible for settling the fees due for a
//! given wallet

use std::{
    error::Error,
    fmt::{Display, Formatter, Result as FmtResult},
};

use alloy::rpc::types::TransactionReceipt;
use async_trait::async_trait;
use circuit_types::{native_helpers::encrypt_note, note::Note};
use circuits::zk_circuits::valid_offline_fee_settlement::{
    SizedValidOfflineFeeSettlementStatement, SizedValidOfflineFeeSettlementWitness,
};
use common::types::{
    proof_bundles::OfflineFeeSettlementBundle, tasks::PayOfflineFeeTaskDescriptor, wallet::Wallet,
};
use darkpool_client::{DarkpoolClient, errors::DarkpoolClientError};
use job_types::{
    network_manager::NetworkManagerQueue,
    proof_manager::{ProofJob, ProofManagerQueue},
};
use num_bigint::BigUint;
use serde::Serialize;
use state::{State, error::StateError};
use tracing::instrument;
use util::{err_str, on_chain::get_protocol_pubkey};

use crate::{
    task_state::StateWrapper,
    traits::{Task, TaskContext, TaskError, TaskState},
    utils::validity_proofs::{
        enqueue_proof_job, enqueue_relayer_redeem_job, find_merkle_path_with_tx,
        update_wallet_validity_proofs,
    },
};

use super::{ERR_BALANCE_MISSING, ERR_NO_MERKLE_PROOF, ERR_WALLET_MISSING};

/// The name of the task
const TASK_NAME: &str = "pay-offline-fee";

/// Error message emitted when the fee amount in the descriptor is more than the
/// fees owed
const ERR_INVALID_FEE_AMOUNT: &str = "Fee amount in descriptor does not equal paid amount";

// --------------
// | Task State |
// --------------

/// Defines the state of the fee payment task
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub enum PayOfflineFeeTaskState {
    /// The task is awaiting scheduling
    Pending,
    /// The task is proving fee payment for the balance
    ProvingPayment,
    /// The task is submitting a fee payment transaction
    SubmittingPayment,
    /// The task is finding the new Merkle opening for the wallet
    FindingOpening,
    /// The task is updating the validity proofs for the wallet
    UpdatingValidityProofs,
    /// The task has finished
    Completed,
}

impl TaskState for PayOfflineFeeTaskState {
    fn commit_point() -> Self {
        PayOfflineFeeTaskState::SubmittingPayment
    }

    fn completed(&self) -> bool {
        matches!(self, PayOfflineFeeTaskState::Completed)
    }
}

impl Display for PayOfflineFeeTaskState {
    fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
        match self {
            PayOfflineFeeTaskState::Pending => write!(f, "Pending"),
            PayOfflineFeeTaskState::ProvingPayment => write!(f, "Proving Payment"),
            PayOfflineFeeTaskState::SubmittingPayment => write!(f, "Submitting Payment"),
            PayOfflineFeeTaskState::FindingOpening => write!(f, "Finding Opening"),
            PayOfflineFeeTaskState::UpdatingValidityProofs => write!(f, "Updating Validity Proofs"),
            PayOfflineFeeTaskState::Completed => write!(f, "Completed"),
        }
    }
}

impl From<PayOfflineFeeTaskState> for StateWrapper {
    fn from(value: PayOfflineFeeTaskState) -> Self {
        StateWrapper::PayOfflineFee(value)
    }
}

// ---------------
// | Task Errors |
// ---------------

/// The error type for the pay fees task
#[derive(Clone, Debug)]
pub enum PayOfflineFeeTaskError {
    /// An error interacting with darkpool
    Darkpool(String),
    /// An error generating a proof for fee payment
    ProofGeneration(String),
    /// An error interacting with the state
    State(String),
    /// An error updating validity proofs after the fees are settled
    UpdateValidityProofs(String),
}

impl TaskError for PayOfflineFeeTaskError {
    fn retryable(&self) -> bool {
        match self {
            PayOfflineFeeTaskError::Darkpool(_)
            | PayOfflineFeeTaskError::State(_)
            | PayOfflineFeeTaskError::ProofGeneration(_)
            | PayOfflineFeeTaskError::UpdateValidityProofs(_) => true,
        }
    }
}

impl Display for PayOfflineFeeTaskError {
    fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
        write!(f, "{self:?}")
    }
}

impl Error for PayOfflineFeeTaskError {}

impl From<StateError> for PayOfflineFeeTaskError {
    fn from(error: StateError) -> Self {
        PayOfflineFeeTaskError::State(error.to_string())
    }
}

impl From<DarkpoolClientError> for PayOfflineFeeTaskError {
    fn from(error: DarkpoolClientError) -> Self {
        PayOfflineFeeTaskError::Darkpool(error.to_string())
    }
}

// -------------------
// | Task Definition |
// -------------------

/// Defines the pay fees task flow
pub struct PayOfflineFeeTask {
    /// Whether the task pays a protocol fee or a relayer fee
    pub is_protocol_fee: bool,
    /// The balance to pay fees for
    pub mint: BigUint,
    /// The wallet that this task pays fees for
    pub old_wallet: Wallet,
    /// The new wallet after fees have been paid
    pub new_wallet: Wallet,
    /// The note generated by the settlement
    pub note: Note,
    /// The proof of `VALID OFFLINE FEE SETTLEMENT` used to pay the fee
    pub proof: Option<OfflineFeeSettlementBundle>,
    /// The transaction receipt of the fee payment
    pub tx: Option<TransactionReceipt>,
    /// The darkpool client used for submitting transactions
    pub darkpool_client: DarkpoolClient,
    /// A hand to the global state
    pub state: State,
    /// The work queue for the proof manager
    pub proof_queue: ProofManagerQueue,
    /// A sender to the network manager's queue
    pub network_sender: NetworkManagerQueue,
    /// The current state of the task
    pub task_state: PayOfflineFeeTaskState,
}

#[async_trait]
impl Task for PayOfflineFeeTask {
    type State = PayOfflineFeeTaskState;
    type Error = PayOfflineFeeTaskError;
    type Descriptor = PayOfflineFeeTaskDescriptor;

    async fn new(descriptor: Self::Descriptor, ctx: TaskContext) -> Result<Self, Self::Error> {
        let old_wallet = ctx
            .state
            .get_wallet(&descriptor.wallet_id)
            .await?
            .ok_or_else(|| PayOfflineFeeTaskError::State(ERR_WALLET_MISSING.to_string()))?;

        // Construct the new wallet
        let (note, new_wallet) = Self::get_wallet_and_note(&descriptor, &old_wallet)?;
        if descriptor.amount != note.amount {
            return Err(PayOfflineFeeTaskError::State(ERR_INVALID_FEE_AMOUNT.to_string()));
        }

        Ok(Self {
            is_protocol_fee: descriptor.is_protocol_fee,
            mint: descriptor.mint,
            old_wallet,
            new_wallet,
            note,
            proof: None,
            tx: None,
            darkpool_client: ctx.darkpool_client,
            state: ctx.state,
            proof_queue: ctx.proof_queue,
            network_sender: ctx.network_queue,
            task_state: PayOfflineFeeTaskState::Pending,
        })
    }

    #[allow(clippy::blocks_in_conditions)]
    #[instrument(skip_all, err, fields(
        task = self.name(),
        state = %self.state(),
        old_wallet_id = %self.old_wallet.wallet_id,
        new_wallet_id = %self.new_wallet.wallet_id,
    ))]
    async fn step(&mut self) -> Result<(), Self::Error> {
        match self.state() {
            PayOfflineFeeTaskState::Pending => {
                self.task_state = PayOfflineFeeTaskState::ProvingPayment;
            },
            PayOfflineFeeTaskState::ProvingPayment => {
                self.generate_proof().await?;
                self.task_state = PayOfflineFeeTaskState::SubmittingPayment;
            },
            PayOfflineFeeTaskState::SubmittingPayment => {
                self.submit_payment().await?;
                self.task_state = PayOfflineFeeTaskState::FindingOpening;
            },
            PayOfflineFeeTaskState::FindingOpening => {
                self.find_merkle_opening().await?;
                self.task_state = PayOfflineFeeTaskState::UpdatingValidityProofs;
            },
            PayOfflineFeeTaskState::UpdatingValidityProofs => {
                self.update_validity_proofs().await?;
                self.task_state = PayOfflineFeeTaskState::Completed;
            },
            PayOfflineFeeTaskState::Completed => {
                panic!("step() called in state Completed")
            },
        }

        Ok(())
    }

    fn completed(&self) -> bool {
        self.task_state.completed()
    }

    fn state(&self) -> Self::State {
        self.task_state.clone()
    }

    fn name(&self) -> String {
        TASK_NAME.to_string()
    }
}

// -----------------------
// | Task Implementation |
// -----------------------

impl PayOfflineFeeTask {
    /// Generate a proof of `VALID OFFLINE FEE SETTLEMENT` for the given
    /// balance
    async fn generate_proof(&mut self) -> Result<(), PayOfflineFeeTaskError> {
        let (statement, witness) = self.get_witness_statement()?;
        let job = ProofJob::ValidOfflineFeeSettlement { witness, statement };

        let proof_recv = enqueue_proof_job(job, &self.proof_queue)
            .map_err(PayOfflineFeeTaskError::ProofGeneration)?;

        // Await the proof
        let bundle = proof_recv.await.map_err(err_str!(PayOfflineFeeTaskError::ProofGeneration))?;
        self.proof = Some(bundle.proof.into());
        Ok(())
    }

    /// Submit the `settle_offline_fee` transaction for the balance
    async fn submit_payment(&mut self) -> Result<(), PayOfflineFeeTaskError> {
        let proof = self.proof.clone().unwrap();
        let tx = self.darkpool_client.settle_offline_fee(&proof).await?;
        self.tx = Some(tx);
        Ok(())
    }

    /// Find the Merkle opening for the new wallet
    async fn find_merkle_opening(&mut self) -> Result<(), PayOfflineFeeTaskError> {
        let tx = self.tx.as_ref().unwrap();
        let merkle_opening = find_merkle_path_with_tx(&self.new_wallet, &self.darkpool_client, tx)?;
        self.new_wallet.merkle_proof = Some(merkle_opening);

        // Update the global state to include the new wallet
        let waiter = self.state.update_wallet(self.new_wallet.clone()).await?;
        waiter.await?;

        // If this was a relayer fee payment and auto-redeem is enabled, enqueue a job
        // for the relayer to redeem the fee
        let auto_redeem = self.state.get_auto_redeem_fees().await?;
        let decryption_key = self.state.get_fee_key().await?.secret_key();
        if !self.is_protocol_fee && auto_redeem && decryption_key.is_some() {
            enqueue_relayer_redeem_job(self.note.clone(), &self.state)
                .await
                .map_err(PayOfflineFeeTaskError::State)?;
        }

        Ok(())
    }

    /// Update the validity proofs for the wallet after fee payment
    async fn update_validity_proofs(&self) -> Result<(), PayOfflineFeeTaskError> {
        update_wallet_validity_proofs(
            &self.new_wallet,
            self.proof_queue.clone(),
            self.state.clone(),
            self.network_sender.clone(),
        )
        .await
        .map_err(PayOfflineFeeTaskError::UpdateValidityProofs)
    }

    // -----------
    // | Helpers |
    // -----------

    /// Clone the old wallet and update it to reflect the fee payment
    fn get_wallet_and_note(
        descriptor: &PayOfflineFeeTaskDescriptor,
        old_wallet: &Wallet,
    ) -> Result<(Note, Wallet), PayOfflineFeeTaskError> {
        let mut new_wallet = old_wallet.clone();
        let balance = new_wallet
            .get_balance_mut(&descriptor.mint)
            .ok_or_else(|| PayOfflineFeeTaskError::State(ERR_BALANCE_MISSING.to_string()))?;
        let note = if descriptor.is_protocol_fee {
            balance.create_protocol_note(get_protocol_pubkey())
        } else {
            balance.create_relayer_note(old_wallet.managing_cluster)
        };

        new_wallet.reblind_wallet();

        Ok((note, new_wallet))
    }

    /// Get the witness and statement for the `VALID OFFLINE FEE SETTLEMENT`
    fn get_witness_statement(
        &self,
    ) -> Result<
        (SizedValidOfflineFeeSettlementStatement, SizedValidOfflineFeeSettlementWitness),
        PayOfflineFeeTaskError,
    > {
        // Get the old wallet's state transition info
        let note = &self.note;
        let wallet = &self.old_wallet;
        let nullifier = wallet.get_wallet_nullifier();
        let opening = wallet
            .merkle_proof
            .clone()
            .ok_or_else(|| PayOfflineFeeTaskError::State(ERR_NO_MERKLE_PROOF.to_string()))?;
        let original_wallet_public_shares = wallet.blinded_public_shares.clone();
        let original_wallet_private_shares = wallet.private_shares.clone();
        let send_index = wallet.get_balance_index(&self.mint).unwrap();

        // Encrypt the note
        let protocol_key = get_protocol_pubkey();
        let key = if self.is_protocol_fee { protocol_key } else { wallet.managing_cluster };
        let note_commitment = note.commitment();

        let (note_ciphertext, encryption_randomness) = encrypt_note(note, &key);

        // Generate new wallet shares
        let new_wallet = &self.new_wallet;
        let new_wallet_commitment = new_wallet.get_wallet_share_commitment();
        let updated_wallet_public_shares = new_wallet.blinded_public_shares.clone();
        let updated_wallet_private_shares = new_wallet.private_shares.clone();

        // Create the witness and statement
        let statement = SizedValidOfflineFeeSettlementStatement {
            merkle_root: opening.compute_root(),
            nullifier,
            new_wallet_commitment,
            updated_wallet_public_shares,
            note_ciphertext,
            note_commitment,
            protocol_key,
            is_protocol_fee: self.is_protocol_fee,
        };

        let witness = SizedValidOfflineFeeSettlementWitness {
            original_wallet_public_shares,
            original_wallet_private_shares,
            updated_wallet_private_shares,
            merkle_opening: opening.into(),
            note: note.clone(),
            encryption_randomness,
            send_index,
        };

        Ok((statement, witness))
    }
}
