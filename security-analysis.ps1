# 🛡️ Renegade Security Analysis Script (PowerShell)
# Run comprehensive security analysis for bug hunting

param(
    [string]$OutputDir = "security-reports"
)

Write-Host "🛡️ Starting Renegade Security Analysis..." -ForegroundColor Blue
Write-Host "🕐 $(Get-Date)" -ForegroundColor Gray

# Create reports directory
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Host "📁 Created $OutputDir directory" -ForegroundColor Blue
}

Set-Location $OutputDir

# Function to run analysis with error handling
function Invoke-Analysis {
    param(
        [string]$Name,
        [scriptblock]$Command
    )
    
    Write-Host "🔍 Running $Name..." -ForegroundColor Yellow
    try {
        & $Command
        Write-Host "✅ $Name completed" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ $Name failed (continuing anyway)" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    Write-Host ""
}

# Install required tools
Write-Host "🔧 Installing security analysis tools..." -ForegroundColor Blue
try {
    cargo install cargo-audit cargo-geiger cargo-deny cargo-outdated --quiet 2>$null
    pip install semgrep --quiet 2>$null
}
catch {
    Write-Host "⚠️ Some tools may not have installed correctly" -ForegroundColor Yellow
}

# 1. Vulnerability Audit
Invoke-Analysis "Vulnerability Audit" {
    Set-Location ..
    cargo audit --json > "$OutputDir/vulnerabilities.json" 2>$null
    cargo audit --color always | Tee-Object "$OutputDir/vulnerabilities.txt"
    Set-Location $OutputDir
}

# 2. Unsafe Code Analysis
Invoke-Analysis "Unsafe Code Analysis" {
    Set-Location ..
    cargo geiger --format GitHubMarkdown > "$OutputDir/unsafe-analysis.md" 2>$null
    Set-Location $OutputDir
}

# 3. Dependency Analysis
Invoke-Analysis "Outdated Dependencies" {
    Set-Location ..
    cargo outdated --root-deps-only > "$OutputDir/outdated-deps.txt" 2>$null
    Set-Location $OutputDir
}

Invoke-Analysis "Dependency Policy Check" {
    Set-Location ..
    if (Test-Path "deny.toml") {
        cargo deny check > "$OutputDir/dependency-policy.txt" 2>$null
    }
    Set-Location $OutputDir
}

# 4. Static Analysis with Clippy
Write-Host "🔍 Running enhanced Clippy analysis..." -ForegroundColor Yellow
try {
    Set-Location ..
    cargo clippy --workspace --all-targets --all-features -- `
      -W clippy::all `
      -W clippy::pedantic `
      -W clippy::nursery `
      -W clippy::cargo `
      -W clippy::suspicious `
      -W clippy::complexity `
      -W clippy::perf `
      -W clippy::correctness `
      -A clippy::missing_docs_in_private_items `
      --message-format json > "$OutputDir/clippy-detailed.json" 2>$null
    
    Write-Host "✅ Clippy analysis completed" -ForegroundColor Green
    Set-Location $OutputDir
}
catch {
    Write-Host "❌ Clippy analysis failed" -ForegroundColor Red
    Set-Location $OutputDir
}
Write-Host ""

# 5. Pattern-based Analysis
Write-Host "🔍 Running pattern-based security analysis..." -ForegroundColor Yellow

# Find unsafe usage
Set-Location ..
Select-String -Path "*.rs" -Pattern "unsafe" -Recurse | Out-File "$OutputDir/unsafe-usage.txt" -Encoding UTF8 2>$null

# Find panic points
Select-String -Path "*.rs" -Pattern "\.unwrap\(\)|\.expect\(|panic!" -Recurse | Out-File "$OutputDir/panic-points.txt" -Encoding UTF8 2>$null

# Find cryptographic patterns
Select-String -Path "*.rs" -Pattern "random|entropy|seed|private_key|secret|signature|hash|encrypt|decrypt" -Recurse | Out-File "$OutputDir/crypto-patterns.txt" -Encoding UTF8 2>$null

# Find potential hardcoded secrets
Select-String -Path "*.rs" -Pattern "secret.*=|key.*=|password.*=" -Recurse | Out-File "$OutputDir/potential-secrets.txt" -Encoding UTF8 2>$null

# Find concurrency patterns
Select-String -Path "*.rs" -Pattern "Mutex|RwLock|Arc|Rc|RefCell|Cell|spawn|thread::" -Recurse | Out-File "$OutputDir/concurrency-patterns.txt" -Encoding UTF8 2>$null

# Find raw pointer usage
Select-String -Path "*.rs" -Pattern "Box::from_raw|Box::into_raw|ptr::|as \*|\*const|\*mut" -Recurse | Out-File "$OutputDir/raw-pointer-usage.txt" -Encoding UTF8 2>$null

Set-Location $OutputDir
Write-Host "✅ Pattern analysis completed" -ForegroundColor Green
Write-Host ""

# 6. Semgrep Security Analysis (if available)
if (Get-Command semgrep -ErrorAction SilentlyContinue) {
    Invoke-Analysis "Semgrep Security Scan" {
        Set-Location ..
        semgrep --config=auto --json --output="$OutputDir/semgrep-security.json" . 2>$null
        Set-Location $OutputDir
    }
} else {
    Write-Host "⚠️ Semgrep not available, skipping..." -ForegroundColor Yellow
}

# 7. Generate Summary Report
Write-Host "📄 Generating security analysis summary..." -ForegroundColor Blue

$analysisDate = Get-Date
$gitRemote = ""
$gitCommit = ""

try {
    Set-Location ..
    $gitRemote = git remote get-url origin 2>$null
    $gitCommit = git rev-parse HEAD 2>$null
    Set-Location $OutputDir
} catch {
    $gitRemote = "Local repository"
    $gitCommit = "Unknown"
    Set-Location $OutputDir
}

# Count vulnerabilities
$vulnCount = "Could not analyze"
if (Test-Path "vulnerabilities.json") {
    try {
        $vulnData = Get-Content "vulnerabilities.json" | ConvertFrom-Json
        $vulnCount = $vulnData.vulnerabilities.Count
    } catch {
        $vulnCount = "Error reading"
    }
}

# Count unsafe blocks
$unsafeCount = 0
if (Test-Path "unsafe-usage.txt") {
    try {
        $unsafeCount = (Get-Content "unsafe-usage.txt").Count
    } catch {
        $unsafeCount = 0
    }
}

# Count panic points
$panicCount = 0
if (Test-Path "panic-points.txt") {
    try {
        $panicCount = (Get-Content "panic-points.txt").Count
    } catch {
        $panicCount = 0
    }
}

# Count crypto patterns
$cryptoCount = 0
if (Test-Path "crypto-patterns.txt") {
    try {
        $cryptoCount = (Get-Content "crypto-patterns.txt").Count
    } catch {
        $cryptoCount = 0
    }
}

# Generate summary markdown
$summaryContent = @"
# 🛡️ Renegade Security Analysis Summary

**Analysis Date**: $analysisDate
**Repository**: $gitRemote
**Commit**: $gitCommit

## 📊 Analysis Results

### 🚨 Vulnerabilities
- **Known Vulnerabilities**: $vulnCount

### ⚠️ Unsafe Code Usage
- **Unsafe Blocks Found**: $unsafeCount locations

### 🎯 Panic Points
- **Potential Panic Points**: $panicCount locations

### 🔐 Cryptographic Code
- **Crypto-related Lines**: $cryptoCount locations

## 📁 Generated Reports

- ``vulnerabilities.json`` / ``vulnerabilities.txt`` - Known vulnerabilities
- ``unsafe-analysis.md`` - Unsafe code analysis
- ``clippy-detailed.json`` - Static analysis findings
- ``crypto-patterns.txt`` - Cryptographic code locations
- ``panic-points.txt`` - Potential panic locations
- ``concurrency-patterns.txt`` - Concurrency-related code
- ``raw-pointer-usage.txt`` - Raw pointer operations
- ``potential-secrets.txt`` - Potential hardcoded secrets

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

- **Critical MPC/Crypto Flaws**: `$50,000 - `$200,000+
- **Memory Safety Issues**: `$10,000 - `$50,000
- **Concurrency Bugs**: `$5,000 - `$25,000
- **Network Protocol Flaws**: `$1,000 - `$15,000

## 🚀 Next Steps

1. **Review all generated reports** for automated findings
2. **Manual code review** of high-risk areas identified above
3. **Fuzz testing** of parser and crypto components
4. **Dynamic analysis** with sanitizers
5. **Formal verification** consideration for critical components

**Happy bug hunting! 🎯**
"@

$summaryContent | Out-File "ANALYSIS_SUMMARY.md" -Encoding UTF8

# Display summary
Write-Host "🎉 Security analysis completed!" -ForegroundColor Green
Write-Host ""
Write-Host "📋 Analysis Summary:" -ForegroundColor Blue
Write-Host "🚨 Vulnerabilities: $vulnCount" -ForegroundColor $(if ($vulnCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "⚠️  Unsafe blocks: $unsafeCount" -ForegroundColor Yellow
Write-Host "💥 Panic points: $panicCount" -ForegroundColor Yellow
Write-Host ""
Write-Host "📁 Reports saved in: $(Get-Location)" -ForegroundColor Blue
Write-Host "📄 Read ANALYSIS_SUMMARY.md for detailed results" -ForegroundColor Blue
Write-Host ""
Write-Host "🔍 Happy hunting! Focus on crypto and unsafe code sections." -ForegroundColor Green
