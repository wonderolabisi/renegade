//! Defines helpers for logging

use std::{error::Error, fmt::Display};
use tracing_subscriber::{
    EnvFilter, Layer, Registry, fmt, layer::SubscriberExt, util::SubscriberInitExt,
};
pub use tracing_subscriber::{filter::LevelFilter, fmt::format::Format};

pub mod datadog;
pub mod helpers;
pub mod metrics;
pub mod otlp_tracer;
pub mod propagation;

/// Possible errors that occur when setting up telemetry
/// for the relayer
#[derive(Debug)]
pub enum TelemetrySetupError {
    /// Error emitted when an expected environment variable is missing
    EnvVarMissing,
    /// Error emitted when setting up the OTLP tracer
    Tracer(String),
    /// Error emitted when the OTLP deployment environemt
    /// is not provided
    DeploymentEnvUnset,
    /// Error emitted when the OTLP collector endpoint is not provided
    CollectorEndpointUnset,
    /// Error emitted when setting up the statsd metrics recorder
    Metrics(String),
}

impl Error for TelemetrySetupError {}
impl Display for TelemetrySetupError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}

/// Initialize a logger at the given log level
pub fn setup_system_logger(level: LevelFilter) {
    tracing_subscriber::fmt().event_format(Format::default().pretty()).with_max_level(level).init();
}

/// A builder for configuring telemetry for the relayer
#[derive(Default)]
pub struct TelemetryBuilder {
    /// The subscriber layers to add to the telemetry stack
    layers: Vec<Box<dyn Layer<Registry> + Send + Sync + 'static>>,
}

impl TelemetryBuilder {
    /// Add a subscriber layer to the telemetry builder
    fn with_layer<L: Layer<Registry> + Send + Sync>(mut self, layer: L) -> Self {
        self.layers.push(layer.boxed());
        self
    }

    /// Configure logging for the relayer
    pub fn with_logging(self, datadog_enabled: bool) -> Self {
        if datadog_enabled {
            opentelemetry::global::set_text_map_propagator(
                opentelemetry_datadog::DatadogPropagator::new(),
            );

            self.with_layer(fmt::layer().json().event_format(datadog::formatter::DatadogFormatter))
        } else {
            self.with_layer(fmt::layer().pretty())
        }
    }

    /// Configure OTLP tracing for the relayer
    pub fn with_tracing(
        self,
        datadog_enabled: bool,
        collector_endpoint: String,
    ) -> Result<Self, TelemetrySetupError> {
        let otlp_tracer = otlp_tracer::configure_otlp_tracer(datadog_enabled, collector_endpoint)?;
        let otlp_trace_layer = tracing_opentelemetry::layer().with_tracer(otlp_tracer);

        Ok(self.with_layer(otlp_trace_layer))
    }

    /// Configure StatsD metrics for the relayer
    pub fn with_metrics(
        self,
        datadog_enabled: bool,
        statsd_host: &str,
        statsd_port: u16,
        config: Option<metrics::MetricsConfig>,
    ) -> Result<Self, TelemetrySetupError> {
        metrics::configure_metrics_statsd_recorder_with_config(
            datadog_enabled,
            statsd_host,
            statsd_port,
            &config.unwrap_or_default(),
        )?;

        Ok(self.with_layer(metrics_tracing_context::MetricsLayer::new()))
    }

    /// Initialize the global subscriber with the configured telemetry layers
    pub fn build(self) {
        let layers = self.layers.with_filter(
            EnvFilter::builder().with_default_directive(LevelFilter::INFO.into()).from_env_lossy(),
        );
        tracing_subscriber::registry().with(layers).init()
    }
}

/// Configures logging, tracing, and metrics for the relayer
/// based on the compilation features enabled
pub fn configure_telemetry(
    datadog_enabled: bool,
    otlp_enabled: bool,
    metrics_enabled: bool,
    collector_endpoint: String,
    statsd_host: &str,
    statsd_port: u16,
) -> Result<(), TelemetrySetupError> {
    configure_telemetry_with_metrics_config(
        datadog_enabled,
        otlp_enabled,
        metrics_enabled,
        collector_endpoint,
        statsd_host,
        statsd_port,
        None,
    )
}

/// Configures logging, tracing, and metrics for the relayer with optional
/// metrics configuration
pub fn configure_telemetry_with_metrics_config(
    datadog_enabled: bool,
    otlp_enabled: bool,
    metrics_enabled: bool,
    collector_endpoint: String,
    statsd_host: &str,
    statsd_port: u16,
    metrics_config: Option<metrics::MetricsConfig>,
) -> Result<(), TelemetrySetupError> {
    let mut telemetry = TelemetryBuilder::default().with_logging(datadog_enabled);

    if otlp_enabled {
        telemetry = telemetry.with_tracing(datadog_enabled, collector_endpoint)?;
    }

    if metrics_enabled {
        telemetry =
            telemetry.with_metrics(datadog_enabled, statsd_host, statsd_port, metrics_config)?;
    }

    telemetry.build();

    Ok(())
}
