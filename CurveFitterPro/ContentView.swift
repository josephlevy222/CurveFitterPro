//
//  ContentView.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 2/19/26.
//

import SwiftUI

struct ContentView: View {
	var body: some View {
		TabView {
			ProjectListView()
				.tabItem { Label("Projects", systemImage: "folder") }
			
			ModelLibraryView()
				.tabItem { Label("Models", systemImage: "function") }
			
			SettingsView()
				.tabItem { Label("Settings", systemImage: "gearshape") }
		}
		.tint(.indigo)
	}
}

#Preview {
    ContentView()
}
