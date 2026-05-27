//
//  ExportButtons.swift
//
//  Created by Joseph Levy on 1/26/25.
//
import SwiftUI
import Utilities

protocol ExportableLayout {
	associatedtype V: View
	
	var jobName: String { get }
	
	@ViewBuilder
	func makeView(isLandscape: Bool) -> V
}

struct MenuItemButtonStyle: ButtonStyle {
	@State private var isHovered = false
	
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.background(
				RoundedRectangle(cornerRadius: 6)
					.fill(configuration.isPressed || isHovered ? Color.accentColor : Color.clear)
			)
			.foregroundStyle(configuration.isPressed || isHovered ? Color.white : Color.primary)
			.onHover { isHovered = $0 }
	}
}

struct ExportMenu<T: ExportableLayout>: View {
	let provider: T
	@State private var isLandscape: Bool = false
	@State private var printScale: CGFloat = 1.0
	@State private var showExport: Bool = false
	@State private var previewItem: PreviewItem? = nil
	
	struct PreviewItem: Identifiable {
		let id = UUID() // Ensures the sheet recognizes it as "new" every time
		let image: UIImage
	}
	
	var body: some View {
		Button { showExport = true } label: {
			Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
		}
		.modalOverlay(isVisible: $showExport, dimBackground: false, blockHits: false) {
			// Pass the state down so the panel can use it
			ExportPanel(
				provider: provider,
				isLandscape: $isLandscape,
				printScale: $printScale,
				previewItem: $previewItem
			)
		}
		.sheet(item: $previewItem) { item in
			PrintPreviewOverlay(image: item.image)
		}
	}
	
	struct ExportPanel: View {
		let provider: T
		@Binding var isLandscape: Bool
		@Binding var printScale: CGFloat
		@Binding var previewItem: PreviewItem?
		
		@Environment(\.dismissModalOverlay) private var dismiss // ModalOverlay dismiss
		
		var body: some View {
			VStack(alignment: .leading, spacing: 0) {
				Toggle("Landscape", isOn: $isLandscape)
					.padding(.horizontal, 12)
					.padding(.vertical, 6)
				
				LabeledContent("Scale: \(printScale, specifier: "%.1f")×") {
					Slider(value: $printScale, in: 0.5...2.0, step: 0.1)
				}
				.padding(.horizontal, 12).padding(.vertical, 6)
				
				Divider()
				
				actionButton("Copy", icon: "doc.on.doc") { UIPasteboard.general.image = $0 }
				
				actionButton("Print", icon: "printer") { _ in
					printDynamicView(provider: provider, isLandscape: $isLandscape, scale: printScale)
				}
				
				actionButton("Preview", icon: "eye", closeMenu: false) { image in
					if let image { previewItem = PreviewItem(image: image) }
				}
			
				saveFileMenu
			}
			.buttonStyle(MenuItemButtonStyle())
			.background(.regularMaterial)
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.shadow(radius: 8)
			.frame(width: 260)
		}
		
		// MARK: - Helper Views & Logic
		
		private func actionButton(_ title: String, icon: String, closeMenu: Bool = true,
								  action: @escaping (UIImage?) -> Void) -> some View {
			Button(title, systemImage: icon) {
				if closeMenu { dismiss?() }
				Task { @MainActor in action(generateSnapshot()) }
			}
		}
		
		private var saveFileMenu: some View {
			Menu("Save to File") {
				Button("PNG File") { performSave { savePNG(image: $0) } }
				Button("JPEG File") { performSave { saveJPG(image: $0) } }
			}
		}
		
		private func performSave(savingLogic: @escaping (UIImage?) -> Void) {
			dismiss?()
			Task { @MainActor in
				savingLogic(generateSnapshot())
			}
		}
		
		@MainActor
		private func generateSnapshot() -> UIImage? {
			let width  = (isLandscape ? 11.0 : 8.5) * Double(printScale) * 72.0
			let height = (isLandscape ? 8.5 : 11.0) * Double(printScale) * 72.0
			return SnapshotUtils.generate(
				for: provider.makeView(isLandscape: isLandscape),
				width: width,
				height: height
			)
		}
		
		@MainActor
		struct SnapshotUtils {
			/// Generates a snapshot using ImageRenderer (iOS 16+) or UIHostingController (iOS 15)
			static func generate(for view: some View, width: CGFloat, height: CGFloat) -> UIImage? {
				let size = CGSize(width: width, height: height)
				
				if #available(iOS 16.0, *) {
					let renderer = ImageRenderer(content: view.frame(width: width, height: height))
					renderer.scale = 3.0
					return renderer.uiImage
				} else {
					// iOS 15 Fallback: The classic UIHostingController approach
					let controller = UIHostingController(rootView: view.frame(width: width, height: height))
					let view = controller.view
					
					view?.bounds = CGRect(origin: .zero, size: size)
					view?.backgroundColor = .clear
					
					let renderer = UIGraphicsImageRenderer(size: size)
					return renderer.image { _ in
						view?.drawHierarchy(in: view!.bounds, afterScreenUpdates: true)
					}
				}
			}
		}
		
		func savePNG(image: UIImage?) {
			if let data = image?.pngData() {
				let filename = getDocumentsDirectory().appendingPathComponent("copy.png")
				print("Filename:", filename)
				if (try? data.write(to: filename)) == nil { print("Save Failed to ", filename)}
			} else { print("Failed to make png data")}
		}
		
		// That call to getDocumentsDirectory() is a little helper function I include in most of my projects,
		// because it makes it easy to locate the user's documents directory where you can save app files. Here it is:
		func getDocumentsDirectory() -> URL {
			let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
			return paths[0]
		}
		
		// If you want to save your image as a JPEG rather than a PNG, use this code instead:
		func saveJPG(image: UIImage?, quality: CGFloat = 0.8) {
			if let data = image?.jpegData(compressionQuality: quality) {
				let filename = getDocumentsDirectory().appendingPathComponent("copy.jpeg")
				print("Filename:", filename)
				if (try? data.write(to: filename)) == nil { print("Save failed to ", filename)}
			} else { print("Failed to make jpeg data")}
		}
		
		class DynamicSwiftUIRenderer: UIPrintPageRenderer {
			let provider: T
			let scale: CGFloat
			
			init(provider: T, scale: CGFloat = 1.0) {
				self.provider = provider
				self.scale = scale
				super.init()
			}
			
			override var numberOfPages: Int { 1 }
			
			override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
				guard printableRect.width > 0 && printableRect.height > 0 else { return }
				
				let isLandscape = printableRect.width > printableRect.height
				var renderedImage: UIImage?
				
				/// We need the semaphore because UIPrintPageRenderer calls this on a background thread, but SwiftUI MUST render on the MainActor.
				let semaphore = DispatchSemaphore(value: 0)
				DispatchQueue.main.async { [weak self] in
					guard let self = self else {
						semaphore.signal()
						return
					}
					
					renderedImage = SnapshotUtils.generate(
						for: self.provider.makeView(isLandscape: isLandscape),
						width: printableRect.width * self.scale,
						height: printableRect.height * self.scale
					)
					semaphore.signal()
				}
				_ = semaphore.wait(timeout: .now() + 5.0)
				
				renderedImage?.draw(in: printableRect)
			}
		}
		
		@MainActor
		func printDynamicView(provider: T, isLandscape: Binding<Bool> = .constant(false), scale: CGFloat = 1.0) {
			let printController = UIPrintInteractionController.shared
			
			let printInfo = UIPrintInfo(dictionary: nil)
			
			printInfo.orientation = isLandscape.wrappedValue ? .landscape : .portrait
			printInfo.outputType = .general
			printInfo.jobName = provider.jobName
			
			// We don't force an orientation here; we let the user choose
			printController.printInfo = printInfo
			
			// Assign the dynamic renderer instead of a printingItem
			let renderer = DynamicSwiftUIRenderer(provider: provider, scale: scale)
			printController.printPageRenderer = renderer
			
			printController.present(animated: true, completionHandler: nil)
			isLandscape.wrappedValue = printInfo.orientation == .landscape
		}
	}
	
	struct PrintPreviewOverlay: View {
		@Environment(\.dismiss) private var dismiss // standard modal dismiss
		let image: UIImage
		
		var body: some View {
			VStack(spacing: 0) {
				HStack {
					Text("Preview")
						.font(.headline)
					Spacer()
					Button("Done") { dismiss() }
				}
				.padding()
				
				Divider()
				
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.background(Color.white)
					.border(Color.primary)
					.padding()
			}
		}
	}
}
