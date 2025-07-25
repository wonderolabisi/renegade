#!/bin/bash

# 🛡️ Renegade Security Analysis Script
# Run comprehensive security analysis for bug hunting

set -e

echo "🛡️ Starting Renegade Security Analysis..."
echo "🕐 $(date)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create reports directory
mkdir -p security-reports
cd security-reports

echo -e "${BLUE}📁 Created security-reports directory${NC}"

# Function to run command with status
run_analysis() {
    local name=$1
    local cmd=$2
    echo -e "${YELLOW}🔍 Running $name...${NC}"
    if eval "$cmd"; then
        echo -e "${GREEN}✅ $name completed${NC}"
    else
        echo -e "${RED}❌ $name failed (continuing anyway)${NC}"
    fi
    echo ""
}

# Install required tools
echo -e "${BLUE}🔧 Installing security analysis tools...${NC}"
cargo install cargo-audit cargo-geiger cargo-deny cargo-outdated --quiet 2>/dev/null || true
pip install semgrep --quiet 2>/dev/null || true

# 1. Vulnerability Audit
run_analysis "Vulnerability Audit" "cd .. && cargo audit --json > security-reports/vulnerabilities.json"
run_analysis "Vulnerability Summary" "cd .. && cargo audit --color always | tee security-reports/vulnerabilities.txt"

# 2. Unsafe Code Analysis  
run_analysis "Unsafe Code Analysis" "cd .. && cargo geiger --format GitHubMarkdown > security-reports/unsafe-analysis.md"

# 3. Dependency Analysis
run_analysis "Outdated Dependencies" "cd .. && cargo outdated --root-deps-only > security-reports/outdated-deps.txt"
run_analysis "Dependency Policy Check" "cd .. && cargo deny check > security-reports/dependency-policy.txt"

# 4. Static Analysis with Clippy
echo -e "${YELLOW}🔍 Running enhanced Clippy analysis...${NC}"
cd ..
cargo clippy --workspace --all-targets --all-features -- \
  -W clippy::all \
  -W clippy::pedantic \
  -W clippy::nursery \
  -W clippy::cargo \
  -W clippy::suspicious \
  -W clippy::complexity \
  -W clippy::perf \
  -W clippy::correctness \
  -A clippy::missing_docs_in_private_items \
  --message-format json > security-reports/clippy-detailed.json 2>/dev/null || true

echo -e "${GREEN}✅ Clippy analysis completed${NC}"
echo ""

# 5. Pattern-based Analysis
echo -e "${YELLOW}🔍 Running pattern-based security analysis...${NC}"

# Find unsafe usage
grep -r "unsafe" --include="*.rs" . > security-reports/unsafe-usage.txt 2>/dev/null || true

# Find panic points
grep -r "\.unwrap()\|\.expect(\|panic!" --include="*.rs" . > security-reports/panic-points.txt 2>/dev/null || true

# Find cryptographic patterns
grep -r "random\|entropy\|seed\|private_key\|secret\|signature\|hash\|encrypt\|decrypt" --include="*.rs" . > security-reports/crypto-patterns.txt 2>/dev/null || true

# Find potential hardcoded secrets
grep -r "secret.*=\|key.*=\|password.*=" --include="*.rs" . > security-reports/potential-secrets.txt 2>/dev/null || true

# Find concurrency patterns
grep -r "Mutex\|RwLock\|Arc\|Rc\|RefCell\|Cell\|spawn\|thread::" --include="*.rs" . > security-reports/concurrency-patterns.txt 2>/dev/null || true

# Find raw pointer usage
grep -r "Box::from_raw\|Box::into_raw\|ptr::\|as \*\|\*const\|\*mut" --include="*.rs" . > security-reports/raw-pointer-usage.txt 2>/dev/null || true

echo -e "${GREEN}✅ Pattern analysis completed${NC}"
echo ""

# 6. Semgrep Security Analysis (if available)
if command -v semgrep &> /dev/null; then
    run_analysis "Semgrep Security Scan" "semgrep --config=auto --json --output=security-reports/semgrep-security.json ."
else
    echo -e "${YELLOW}⚠️ Semgrep not available, skipping...${NC}"
fi

# 7. Generate Summary Report
echo -e "${BLUE}📄 Generating security analysis summary...${NC}"

cat > security-reports/ANALYSIS_SUMMARY.md << EOF
# 🛡️ Renegade Security Analysis Summary

**Analysis Date**: $(date)
**Repository**: $(git remote get-url origin 2>/dev/null || echo "Local repository")
**Commit**: $(git rev-parse HEAD 2>/dev/null || echo "Unknown")

## 📊 Analysis Results

### 🚨 Vulnerabilities
$(if [ -f vulnerabilities.json ]; then
    vulns=$(jq '.vulnerabilities | length' vulnerabilities.json 2>/dev/null || echo "Error reading")
    echo "- **Known Vulnerabilities**: $vulns"
else
    echo "- **Known Vulnerabilities**: Could not analyze"
fi)

### ⚠️ Unsafe Code Usage
$(if [ -f unsafe-usage.txt ]; then
    unsafe_count=$(wc -l < unsafe-usage.txt 2>/dev/null || echo "0")
    echo "- **Unsafe Blocks Found**: $unsafe_count locations"
else
    echo "- **Unsafe Blocks**: Could not analyze"
fi)

### 🎯 Panic Points
$(if [ -f panic-points.txt ]; then
    panic_count=$(wc -l < panic-points.txt 2>/dev/null || echo "0")
    echo "- **Potential Panic Points**: $panic_count locations"
else
    echo "- **Panic Points**: Could not analyze"
fi)

### 🔐 Cryptographic Code
$(if [ -f crypto-patterns.txt ]; then
    crypto_count=$(wc -l < crypto-patterns.txt 2>/dev/null || echo "0")
    echo "- **Crypto-related Lines**: $crypto_count locations"
else
    echo "- **Crypto Patterns**: Could not analyze"
fi)

## 📁 Generated Reports

- \`vulnerabilities.json\` / \`vulnerabilities.txt\` - Known vulnerabilities
- \`unsafe-analysis.md\` - Unsafe code analysis
- \`clippy-detailed.json\` - Static analysis findings
- \`crypto-patterns.txt\` - Cryptographic code locations
- \`panic-points.txt\` - Potential panic locations
- \`concurrency-patterns.txt\` - Concurrency-related code
- \`raw-pointer-usage.txt\` - Raw pointer operations
- \`potential-secrets.txt\` - Potential hardcoded secrets

## 🎯 High-Priority Manual Review Areas

### 🔐 Cryptographic Security
1. **Key Management**: Review key generation, storage, and zeroization
2. **Constant-Time Operations**: Ensure timing attack resistance
3. **Random Number Generation**: Verify entropy sources
4. **Multi-Party Computation**: Review MPC protocol implementation

### 🧵 Concurrency Safety
1. **Lock Ordering**: Check for potential deadlocks
2. **Atomic Operations**: Verify correctness of lockless code
3. **Channel Communication**: Review message passing safety

### 🛡️ Memory Safety  
1. **Unsafe Blocks**: Justify all unsafe code usage
2. **Raw Pointers**: Verify pointer arithmetic safety
3. **Buffer Operations**: Check bounds and overflow protection

### 🌐 Network Security
1. **Message Parsing**: Review deserialization safety
2. **DOS Protection**: Check resource exhaustion protection
3. **Protocol Implementation**: Review P2P protocol security

## 💰 Potential Bug Values

- **Critical MPC/Crypto Flaws**: \$50,000 - \$200,000+
- **Memory Safety Issues**: \$10,000 - \$50,000
- **Concurrency Bugs**: \$5,000 - \$25,000
- **Network Protocol Flaws**: \$1,000 - \$15,000

## 🚀 Next Steps

1. **Review all generated reports** for automated findings
2. **Manual code review** of high-risk areas identified above
3. **Fuzz testing** of parser and crypto components
4. **Dynamic analysis** with sanitizers
5. **Formal verification** consideration for critical components

**Happy bug hunting! 🎯**
EOF

cd security-reports

# Display summary
echo -e "${GREEN}🎉 Security analysis completed!${NC}"
echo ""
echo -e "${BLUE}📋 Analysis Summary:${NC}"

if [ -f vulnerabilities.json ]; then
    vulns=$(jq '.vulnerabilities | length' vulnerabilities.json 2>/dev/null || echo "Error")
    echo -e "🚨 Vulnerabilities: ${RED}$vulns${NC}"
fi

if [ -f unsafe-usage.txt ]; then
    unsafe_count=$(wc -l < unsafe-usage.txt 2>/dev/null || echo "0")
    echo -e "⚠️  Unsafe blocks: ${YELLOW}$unsafe_count${NC}"
fi

if [ -f panic-points.txt ]; then
    panic_count=$(wc -l < panic-points.txt 2>/dev/null || echo "0")
    echo -e "💥 Panic points: ${YELLOW}$panic_count${NC}"
fi

echo ""
echo -e "${BLUE}📁 Reports saved in: $(pwd)${NC}"
echo -e "${BLUE}📄 Read ANALYSIS_SUMMARY.md for detailed results${NC}"
echo ""
echo -e "${GREEN}🔍 Happy hunting! Focus on crypto and unsafe code sections.${NC}"
