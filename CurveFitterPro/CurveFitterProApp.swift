//
//  CurveFitterProApp.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 2/19/26.
//

import SwiftUI
import SwiftData
@main
struct CurveFitterProApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
				.modelContainer(for: [Project.self, UserModel.self])
        }
    }
}
