//
//  CurveFitterProApp.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 2/19/26.
//

import SwiftUI
import SwiftData
import Utilities

@main
struct CurveFitterProApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
				.modalOverlayRoot()
				.modelContainer(for: [Project.self, UserModel.self])
				//.keyboardObserver()
        }
    }
}
