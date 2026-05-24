//
//  ExportButtons.swift
//
//  Created by Joseph Levy on 1/26/25.
//
import SwiftUI

public struct ExportImageButton: View {
	internal init(image: @escaping () -> UIImage) {
		self.image = image
	}
	let image: () -> UIImage
	let label = Label("Export", systemImage:  "square.and.arrow.up")
	public var body: some View {
		Menu {
			Button("Copy", systemImage: "doc.on.doc") {
				UIPasteboard.general.image = image()
			}
			Button("Print", systemImage: "printer") {
				printUIImage(image())
			}
			Menu("Save to File") {
				Button("PNG File", systemImage: "folder") {
					savePNG(image: image())
				}
				Button("JPEG File", systemImage: "folder") {
					saveJPG(image: image())
				}
			}
		} label: { label }
	}
}

struct ExportViewButton<Content: View> : View {
	internal init(_ view: @escaping () -> Content) {
		self.image = { view().snapshot() }//image
	}
	let image: () -> UIImage
	let label = Label("Export", systemImage:  "square.and.arrow.up")
	var body: some View {
		Menu {
			Button("Copy", systemImage: "doc.on.doc") {
				UIPasteboard.general.image = image()
			}
			Button("Print", systemImage: "printer") {
				printUIImage(image())
			}
			Menu("Save to File") {
				Button("PNG File", systemImage: "folder") {
					savePNG(image: image())
				}
				Button("JPEG File", systemImage: "folder") {
					saveJPG(image: image())
				}
			}
		} label: { label }
	}
}

//func printUIImage(_ image: UIImage) {
//	let printController = UIPrintInteractionController.shared
//	
//	let printInfo = UIPrintInfo(dictionary: nil)
//	printInfo.outputType = .photo
//	printInfo.jobName = "Print My SwiftUI View"
//	
//	printController.printInfo = printInfo
//	printController.printingItem = image
//	if let paperSize = printController.printPaper?.paperSize { print("Paper Size: \(paperSize)")}
//	else { print("No paper size")}
//	printController.present(animated: true, completionHandler: nil)
//}
func printUIImage(_ image: UIImage) {
	let printController = UIPrintInteractionController.shared
	
	let printInfo = UIPrintInfo(dictionary: nil)
	printInfo.outputType = .photo
	printInfo.jobName = "Print My SwiftUI View"
	
	printController.printInfo = printInfo
	printController.printingItem = image
	
	if let paperSize = printController.printPaper?.paperSize {
		print("Paper Size: \(paperSize)")
	} else {
		print("No paper size")
	}
	#if targetEnvironment(macCatalyst)
	// On Mac Catalyst, present(animated:) doesn't work — must supply a source rect
	if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
	   let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
		let center = CGRect(
			x: window.bounds.midX,
			y: window.bounds.midY,
			width: 1,
			height: 1
		)
		printController.present(from: center, in: window, animated: true, completionHandler: nil)
	}
	#else
	printController.present(animated: true, completionHandler: nil)
	#endif
}
func savePNG(image: UIImage) {
	if let data = image.pngData() {
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
func saveJPG(image: UIImage, quality: CGFloat = 0.8) {
	if let data = image.jpegData(compressionQuality: quality) {
		let filename = getDocumentsDirectory().appendingPathComponent("copy.jpeg")
		print("Filename:", filename)
		if (try? data.write(to: filename)) == nil { print("Save failed to ", filename)}
	} else { print("Failed to make jpeg data")}
}
// The parameter to jpegData() is a float that represents JPEG quality, where 1.0 is highest and 0.0 is lowest.

//func savePDF(docName : String?, content: () -> any View) {
//	guard let saveURL = showSavePDFPanel(docName) else {
//		return
//	}
//	var mediaBox = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 1100, height: 600))
//	
//	if let dataConsumer = CGDataConsumer(url: saveURL as CFURL) {
//		if let pdfContext = CGContext(consumer: dataConsumer, mediaBox: &mediaBox, nil) {
//			let options: [CFString: Any] = [kCGPDFContextMediaBox: mediaBox]
//			
//			for sem in ItrSemester.allCases {
//				pdfContext.beginPDFPage(options as CFDictionary)
//				let renderer = ImageRenderer(content: Content)
//				renderer.render { size, renderFunction in
//					pdfContext.translateBy(x: (mediaBox.width - size.width) / 2.0,
//										   y: (mediaBox.height - size.height) / 2.0)
//					renderFunction(pdfContext)
//				}
//				
//				/// Add a day header to each page with document name
//				let titleString = "\(docName ?? "Ohne Titel")"
//				let attrs : [NSAttributedString.Key : Any] = [.font: NSFont.boldSystemFont(ofSize: 16.0)]
//				let day  = NSAttributedString(string: titleString, attributes: attrs)
//				let path = CGMutablePath()
//				let strWidth  = day.size().width + 1
//				let strHeight = day.size().height + 1
//				let dayXPos   = 20.0
//				let dayYPos   = mediaBox.height - strHeight - 32
//				path.addRect(CGRect(x: dayXPos, y: dayYPos, width: strWidth, height: strHeight))
//				let fSetter = CTFramesetterCreateWithAttributedString(day as CFAttributedString)
//				let frame = CTFramesetterCreateFrame(fSetter, CFRangeMake(0, day.length), path, nil)
//				CTFrameDraw(frame, pdfContext)
//				
//				pdfContext.endPDFPage()
//			}
//			pdfContext.closePDF()
//		}
//	}
//}

public extension View {
	func snapshot() -> UIImage {
		let controller = UIHostingController(rootView: self.edgesIgnoringSafeArea(.all))
		/// Note: The.edgesIgnoringSafeArea(.all) is needed too avoid clipping
		let targetSize = controller.view.intrinsicContentSize
		controller.view.bounds = CGRect(origin: .zero, size: targetSize)
		controller.view.backgroundColor = .clear
		let renderer = UIGraphicsImageRenderer(size: targetSize)
		return renderer.image { _ in
			controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
		}
	}
}
