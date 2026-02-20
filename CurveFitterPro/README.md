# Curve Fitter Pro — iOS Source Code

A scientific nonlinear curve fitting app for iOS 17+ built with SwiftUI, SwiftData, and Swift Charts.

## Architecture

```
Sources/
├── CurveFitterProApp.swift          — App entry point, SwiftData container setup
│
├── Models/
│   ├── DataModels.swift             — DataPoint, FitParameter, FitResult, Project (@Model), UserModel
│   └── ModelLibrary.swift          — 18 built-in scientific models in 6 categories
│
├── ExpressionParser/
│   └── ExpressionParser.swift      — Recursive-descent math parser + evaluator + CompiledExpression
│
├── Solver/
│   ├── LMSolver.swift              — Pure-Swift Levenberg-Marquardt nonlinear least-squares solver
│   └── FittingEngine.swift         — High-level fitting coordinator: statistics, confidence bands, curves
│
├── Utils/
│   └── DataImporter.swift          — CSV/TSV/text parser + DocumentPickerView UIViewControllerRepresentable
│
└── Views/
    ├── ContentView.swift            — TabView root (Projects / Models / Settings)
    ├── ProjectListView.swift        — Project CRUD list with fit summary badges
    ├── ProjectDetailView.swift      — 4-tab project workspace (Data / Model / Fit / Plot)
    └── Views.swift                  — All sub-views: DataEditorView, ModelSetupView, FitRunView,
                                       PlotView, ModelPickerSheet, CustomModelSheet, ModelLibraryView,
                                       ModelDetailView, SettingsView
```

## Key Technical Decisions

### Pure-Swift LM Solver
Rather than depending on CMinpack (C library) at this stage, the LM solver is
implemented in pure Swift for simplicity and portability. For production you may
want to swap in CMinpack or lmfit via a bridging header for better performance
on large datasets (>10,000 points).

### Expression Parser
A custom recursive-descent parser handles arbitrary math expressions.
Supported operations: `+`, `-`, `*`, `/`, `^` (power), unary minus.
Built-in functions: `exp`, `log`, `log10`, `log2`, `sqrt`, `abs`,
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `pow`,
`sign`, `ceil`, `floor`, `min`, `max`.
Constants: `pi`, `e`.

The parser automatically extracts parameter names (any identifier that isn't `x`, `pi`, or `e`),
populating the parameter table without any user configuration.

### Numerical Jacobian
Derivatives are computed via central finite differences. This means the user
never needs to supply analytical gradients — any valid expression can be fitted
immediately.

### Statistics
- Covariance matrix: `s² × (JᵀJ)⁻¹` where `s² = RSS / (n - p)`
- Standard errors: `sqrt(diag(Cov))`
- 95% Confidence intervals: `±t_{α/2, n-p} × SE`  (t-critical values tabulated)
- R²: `1 - RSS / SSTot`
- Confidence band: error propagation via gradient · Cov · gradient

## Requirements
- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## Getting Started

1. Clone this repo
2. Open `Package.swift` in Xcode or create a new iOS App project and add these source files
3. Ensure `SwiftData` and `Charts` frameworks are linked (both included in iOS 17 SDK)
4. Build and run on iOS 17 simulator or device

## Next Steps / TODO

- [ ] Export plot as PDF/PNG via `ImageRenderer`
- [ ] Export results as CSV (`ShareLink` + formatted string)
- [ ] iCloud sync via CloudKit
- [ ] Upgrade to CMinpack C library for performance (via bridging header)
- [ ] Add covariance matrix display in Fit Results
- [ ] Log-scale axes toggle
- [ ] Multiple dataset overlay on one plot
- [ ] Auto-initial-guess heuristics per model type
- [ ] Sum of Gaussians model with variable N peaks
- [ ] iPad split-view layout

## Built-in Model Categories

| Category | Models |
|---|---|
| Growth & Decay | Single/double exponential decay, exponential growth, exponential plateau |
| Sigmoidal / Dose-Response | 4PL, Hill equation, Boltzmann sigmoid |
| Enzyme Kinetics | Michaelis-Menten, substrate inhibition |
| Peak / Spectral | Gaussian, Lorentzian, asymmetric Gaussian |
| Pharmacokinetics | One-compartment IV bolus, one-compartment oral |
| Polynomial & Power | Power law, logarithmic, quadratic |
| Oscillation | Damped sine wave, sine wave |
