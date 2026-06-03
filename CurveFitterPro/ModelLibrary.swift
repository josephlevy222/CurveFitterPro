import Foundation

// MARK: - Model Library

struct ModelLibrary {
	
	// 1. Storage URL path in the user's writeable Documents folder
	private static var fileURL: URL {
		let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
		return paths[0].appendingPathComponent("models.json")
	}
	
	// 2. Mutable runtime library array loaded at app launch
	static var all: [BuiltinModel] = loadOrCreateLibrary() {
		didSet {
			// 🔄 AUTOMATIC SAVE: Whenever 'all' changes, write it to disk immediately!
			save(models: all)
		}
	}
	
	// 3. Document persistence check / factory bootstrap loader
	private static func loadOrCreateLibrary() -> [BuiltinModel] {
		// If the writeable JSON file exists in Documents, attempt to load it
		if FileManager.default.fileExists(atPath: fileURL.path) {
			do {
				let data = try Data(contentsOf: fileURL)
				let decoded = try JSONDecoder().decode([BuiltinModel].self, from: data)
				print("✅ Successfully loaded \(decoded.count) models from models.json storage.")
				if !decoded.isEmpty { return decoded }
			} catch {
				print("⚠️ Found models.json on disk, but failed to decode it. Error: \(error)")
				print("Falling back to fresh factory defaults...")
			}
		} else {
			print("ℹ️ First launch: No models.json found in Documents directory. Bootstrapping library...")
		}
		
		// Fallback: Parse from the built-in factory default JSON string literal
		let defaults = factoryDefaults
		
		// Immediately persist to disk so it's ready for custom modifications
		save(models: defaults)
		return defaults
	}
	
	// Save mutations back down to local storage atomically
	static func save(models: [BuiltinModel]) {
		do {
			if models.isEmpty { print("❌ Failed to write models is empty.");return }
			let data = try JSONEncoder().encode(models)
			try data.write(to: fileURL, options: .atomic)
			print("💾 Saved \(models.count) models to disk.")
		} catch {
			print("❌ Failed to write models to disk: \(error)")
		}
	}
	
	// 4. JSON Reader with detailed console error catching
	private static var factoryDefaults: [BuiltinModel] {
		guard let data = defaultJSON.data(using: .utf8) else {
			print("❌ Critical Error: Cannot convert defaultJSON string to UTF8 Data.")
			return []
		}
		
		do {
			let decoded = try JSONDecoder().decode([BuiltinModel].self, from: data)
			return decoded
		} catch {
			print("❌ JSON Decoding Failed! Check your Xcode console output below for the exact cause:")
			print("➡️ Detailed DecodingError: \(error)")
			return []
		}
	}
	// 5. Raw Factory Core Database Map
	private static let defaultJSON = #"""
 [
   {
  "name": "Linear",
  "category": "Polynomial & Power",
  "equation": "y = a·x + b",
  "expression": "a * x + b",
  "parameterNames": ["a", "b"],
  "defaultValues": [1.0, 0.0],
  "description": "Straight line through data.",
  "typicalUseCase": "Calibration curves, linear relationships, Beer-Lambert law"
   },
   {
  "name": "Quadratic",
  "category": "Polynomial & Power",
  "equation": "y = a·x² + b·x + c",
  "expression": "a * x * x + b * x + c",
  "parameterNames": ["a", "b", "c"],
  "defaultValues": [1.0, 0.0, 0.0],
  "description": "Second-degree polynomial.",
  "typicalUseCase": "Parabolic trajectories, calibration curves"
   },
   {
  "name": "Cubic",
  "category": "Polynomial & Power",
  "equation": "y = a·x³ + b·x² + c·x + d",
  "expression": "a * x * x * x + b * x * x + c * x + d",
  "parameterNames": ["a", "b", "c", "d"],
  "defaultValues": [1.0, 0.0, 0.0, 0.0],
  "description": "Third-degree polynomial.",
  "typicalUseCase": "S-shaped calibration curves, nonlinear trends"
   },
   {
  "name": "Power Law",
  "category": "Polynomial & Power",
  "equation": "y = a · x^b",
  "expression": "a * pow(x, b)",
  "parameterNames": ["a", "b"],
  "defaultValues": [1.0, 1.0],
  "description": "Power law (allometric) relationship.",
  "typicalUseCase": "Allometry, fractal scaling, economy of scale"
   },
   {
  "name": "Logarithmic",
  "category": "Polynomial & Power",
  "equation": "y = a · ln(x) + b",
  "expression": "a * log(x) + b",
  "parameterNames": ["a", "b"],
  "defaultValues": [1.0, 0.0],
  "description": "Logarithmic relationship.",
  "typicalUseCase": "Psychophysics (Weber-Fechner), adsorption isotherms"
   },
   {
  "name": "Single Exponential Decay",
  "category": "Growth & Decay",
  "equation": "y = a · e^(−b·x) + c",
  "expression": "a * exp(-b * x) + c",
  "parameterNames": ["a", "b", "c"],
  "defaultValues": [1.0, 0.1, 0.0],
  "description": "Single-phase exponential decay toward a plateau.",
  "typicalUseCase": "Radioactive decay, fluorescence lifetime, drug washout"
   },
   {
  "name": "Double Exponential Decay",
  "category": "Growth & Decay",
  "equation": "y = a·e^(−b·x) + c·e^(−d·x)",
  "expression": "a * exp(-b * x) * c * exp(-d * x)",
  "parameterNames": ["a", "b", "c", "d"],
  "defaultValues": [1.0, 0.5, 0.5, 0.05],
  "description": "Two-phase exponential decay — fast and slow components.",
  "typicalUseCase": "Biexponential pharmacokinetics, fluorescence decay"
   },
   {
  "name": "Exponential Growth",
  "category": "Growth & Decay",
  "equation": "y = a · e^(b·x)",
  "expression": "a * exp(b * x)",
  "parameterNames": ["a", "b"],
  "defaultValues": [1.0, 0.1],
  "description": "Unrestricted exponential growth.",
  "typicalUseCase": "Early-phase bacterial growth, compound interest"
   },
   {
  "name": "Exponential Plateau",
  "category": "Growth & Decay",
  "equation": "y = a · (1 − e^(−b·x))",
  "expression": "a * (1 - exp(-b * x))",
  "parameterNames": ["a", "b"],
  "defaultValues": [1.0, 0.1],
  "description": "Exponential approach to a maximum plateau.",
  "typicalUseCase": "Ligand binding saturation, RC charging"
   },
   {
  "name": "Four-Parameter Logistic (4PL)",
  "category": "Sigmoidal / Dose-Response",
  "equation": "y = d + (a−d) / (1 + (x/c)^b)",
  "expression": "d + (a - d) / (1 + pow(x / c, b))",
  "parameterNames": ["a", "b", "c", "d"],
  "defaultValues": [0.0, 1.0, 1.0, 1.0],
  "description": "Symmetric sigmoid; a=bottom, d=top, c=EC50, b=HillSlope.",
  "typicalUseCase": "ELISA, drug dose-response, immunoassay calibration"
   },
   {
  "name": "Hill Equation",
  "category": "Sigmoidal / Dose-Response",
  "equation": "y = Vmax · x^n / (K^n + x^n)",
  "expression": "Vmax * pow(x, n) / (pow(K, n) + pow(x, n))",
  "parameterNames": ["Vmax", "K", "n"],
  "defaultValues": [1.0, 1.0, 1.0],
  "description": "Hill equation; n=cooperativity coefficient.",
  "typicalUseCase": "Enzyme cooperativity, receptor binding, oxygen-hemoglobin"
   },
   {
  "name": "Boltzmann Sigmoid",
  "category": "Sigmoidal / Dose-Response",
  "equation": "y = bottom + (top−bottom) / (1 + exp((V50−x)/slope))",
  "expression": "\\bottom + (\\top - \\bottom) / (1 + exp((V50 - x) / \\slope))",
  "parameterNames": ["bottom", "top", "V50", "slope"],
  "defaultValues": [0.0, 1.0, 0.0, 1.0],
  "description": "Boltzmann sigmoid, common in electrophysiology.",
  "typicalUseCase": "Ion channel gating, voltage-dependent conductance"
   },
   {
  "name": "Michaelis-Menten",
  "category": "Enzyme Kinetics",
  "equation": "y = Vmax · x / (Km + x)",
  "expression": "Vmax * x / (Km + x)",
  "parameterNames": ["Vmax", "Km"],
  "defaultValues": [1.0, 1.0],
  "description": "Classic Michaelis-Menten enzyme kinetics.",
  "typicalUseCase": "Enzyme velocity vs substrate concentration"
   },
   {
  "name": "Substrate Inhibition",
  "category": "Enzyme Kinetics",
  "equation": "y = Vmax · x / (Km + x·(1 + x/Ki))",
  "expression": "Vmax * x / (Km + x * (1 + x / Ki))",
  "parameterNames": ["Vmax", "Km", "Ki"],
  "defaultValues": [1.0, 1.0, 10.0],
  "description": "Michaelis-Menten with substrate inhibition at high [S].",
  "typicalUseCase": "Enzymes showing bell-shaped velocity curves"
   },
   {
  "name": "Gaussian Peak",
  "category": "Peak / Spectral",
  "equation": "y = a · exp(−(x−μ)² / (2σ²))",
  "expression": "a * exp(-(x - mu) * (x - mu) / (2 * sigma * sigma))",
  "parameterNames": ["a", "mu", "sigma"],
  "defaultValues": [1.0, 0.0, 1.0],
  "description": "Gaussian (normal) peak shape.",
  "typicalUseCase": "Spectroscopy, chromatography, particle size distribution"
   },
   {
  "name": "Lorentzian Peak",
  "category": "Peak / Spectral",
  "equation": "y = a · (γ²) / ((x−x0)² + γ²)",
  "expression": "a * (gamma * gamma) / ((x - x0) * (x - x0) + gamma * gamma)",
  "parameterNames": ["a", "x0", "gamma"],
  "defaultValues": [1.0, 0.0, 1.0],
  "description": "Lorentzian (Cauchy) peak — heavier tails than Gaussian.",
  "typicalUseCase": "NMR spectroscopy, resonance line shapes"
   },
   {
  "name": "Asymmetric Gaussian",
  "category": "Peak / Spectral",
  "equation": "y = a · exp(−(x−μ)² / (2·σ(x)²)), σ varies each side",
  "expression": "a * exp(-(x - mu)*(x - mu) / (2 * pow(x < mu ? sigma1 : sigma2, 2)))",
  "parameterNames": ["a", "mu", "sigma1", "sigma2"],
  "defaultValues": [1.0, 0.0, 1.0, 1.5],
  "description": "Gaussian with different widths on each side of the peak.",
  "typicalUseCase": "Asymmetric chromatographic peaks, skewed distributions"
   },
   {
  "name": "One-Compartment IV Bolus",
  "category": "Pharmacokinetics",
  "equation": "C = C0 · e^(−ke·t)",
  "expression": "C0 * exp(-ke * x)",
  "parameterNames": ["C0", "ke"],
  "defaultValues": [10.0, 0.1],
  "description": "One-compartment PK after IV bolus dose.",
  "typicalUseCase": "Drug plasma concentration vs time after IV injection"
   },
   {
  "name": "One-Compartment Oral",
  "category": "Pharmacokinetics",
  "equation": "C = (F·D·ka)/(V·(ka−ke)) · (e^(−ke·t) − e^(−ka·t))",
  "expression": "F * D * ka / (V * (ka - ke)) * (exp(-ke * x) - exp(-ka * x))",
  "parameterNames": ["F", "D", "ka", "ke", "V"],
  "defaultValues": [1.0, 100.0, 1.0, 0.1, 10.0],
  "description": "One-compartment oral absorption PK model.",
  "typicalUseCase": "Oral drug absorption and elimination"
   },
   {
  "name": "Damped Sine Wave",
  "category": "Oscillation",
  "equation": "y = a · e^(−b·x) · sin(ω·x + φ)",
  "expression": "a * exp(-b * x) * sin(omega * x + phi)",
  "parameterNames": ["a", "b", "omega", "phi"],
  "defaultValues": [1.0, 0.1, 1.0, 0.0],
  "description": "Exponentially damped sinusoidal oscillation.",
  "typicalUseCase": "Mechanical resonance, NMR FID decay, LC circuit"
   },
   {
  "name": "Sine Wave",
  "category": "Oscillation",
  "equation": "y = a · sin(ω·x + φ) + offset",
  "expression": "a * sin(omega * x + phi) + \\offset",
  "parameterNames": ["a", "omega", "phi", "offset"],
  "defaultValues": [1.0, 1.0, 0.0, 0.0],
  "description": "Simple sinusoidal oscillation with offset.",
  "typicalUseCase": "Periodic signals, circadian rhythm data"
   }
 ]
 """#
	
	// MARK: - Search & Category APIs
	
	static var categories: [String] {
		var seen = Set<String>()
		return all.filter { seen.insert($0.category).inserted }.map(\.category)
	}
	
	static func models(in category: String) -> [BuiltinModel] {
		all.filter { $0.category == category }
	}
	
	static func search(_ query: String) -> [BuiltinModel] {
		guard !query.isEmpty else { return all }
		let q = query.lowercased()
		return all.filter {
			$0.name.lowercased().contains(q) ||
			$0.category.lowercased().contains(q) ||
			$0.typicalUseCase.lowercased().contains(q) ||
			$0.description.lowercased().contains(q)
		}
	}
	
#if DEBUG
	/// Completely wipes the document storage cache and reloads initial configurations.
	static func resetToFactoryDefaults() {
		let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
		let fileURL = paths[0].appendingPathComponent("models.json")
		
		// 1. Evict file from disk
		try? FileManager.default.removeItem(at: fileURL)
		print("🗑️ Debug: models.json has been removed from disk storage.")
		
		// 2. Force the internal array to bootstrap back from factory defaults
		// Note: Assuming your bundle loader code lives inside your internal bootstrap function
		self.all = loadOrCreateLibrary()
	}
#endif
}
