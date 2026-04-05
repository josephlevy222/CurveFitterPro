//
//  KeyboardObserver.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 3/26/26.
//
import SwiftUI
import Combine

// MARK: - Keyboard Observer Engine

final class KeyboardObserver: ObservableObject {
	@Published var isVisible: Bool = false
	@Published var height: CGFloat = 0
	
	private var cancellables = Set<AnyCancellable>()
	
	init() {
		NotificationCenter.default.publisher(
			for: UIResponder.keyboardWillChangeFrameNotification
		)
		.compactMap { notification -> (Bool, CGFloat)? in
			guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
				return nil
			}
			
			let screenHeight = UIScreen.main.bounds.height
			
			// Keyboard is visible if its top is above the bottom of the screen
			let visible = frame.minY < screenHeight
			
			// Height is only meaningful when visible
			let height = visible ? frame.height : 0
			
			return (visible, height)
		}
		.receive(on: RunLoop.main)
		.sink { [weak self] visible, height in
			self?.isVisible = visible
			self?.height = height
		}
		.store(in: &cancellables)
	}
}

// MARK: - Environment Keys

private struct KeyboardVisibleKey: EnvironmentKey {
	static let defaultValue: Bool = false
}

private struct KeyboardHeightKey: EnvironmentKey {
	static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
	var keyboardVisible: Bool {
		get { self[KeyboardVisibleKey.self] }
		set { self[KeyboardVisibleKey.self] = newValue }
	}
	
	var keyboardHeight: CGFloat {
		get { self[KeyboardHeightKey.self] }
		set { self[KeyboardHeightKey.self] = newValue }
	}
}

// MARK: - View Modifier

struct KeyboardObserverModifier: ViewModifier {
	@StateObject private var observer = KeyboardObserver()
	
	func body(content: Content) -> some View {
		content
			.environment(\.keyboardVisible, observer.isVisible)
			.environment(\.keyboardHeight, observer.height)
	}
}

extension View {
	func keyboardObserver() -> some View {
		self.modifier(KeyboardObserverModifier())
	}
}

// MARK: - Example Usage (Optional)

/*
 struct DemoView: View {
 @Environment(\.keyboardVisible) private var keyboardVisible
 @Environment(\.keyboardHeight) private var keyboardHeight
 
 @State private var text = ""
 
 var body: some View {
 VStack {
 TextField("Type…", text: $text)
 .textFieldStyle(.roundedBorder)
 
 Text("Keyboard visible: \(keyboardVisible.description)")
 Text("Keyboard height: \(keyboardHeight)")
 }
 .padding()
 .keyboardObserver()
 }
 }
 */

