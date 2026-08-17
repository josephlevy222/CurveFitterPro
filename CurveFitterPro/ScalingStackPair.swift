//
//  ScalingStackPair.swift
//  Mode Analyzer-1D
//
//  Created by Joseph Levy on 2/12/25.
//

import SwiftUI

struct ScalingStackPair<Content1: View, Content2: View>: View {
	internal init(portrait: Bool = true, height: CGFloat, scale: CGFloat = 0.8,
				  content1: @escaping () -> Content1, content2: @escaping () -> Content2) {
#if targetEnvironment(macCatalyst)
		self.scale = 1.0
#else
		self.scale = portrait ? 1.0 : scale
#endif
		self.content1 = content1
		self.content2 = content2
		self.portrait = portrait
		self.height = height // can add 10 to make sure there is room in portrait
	}
	let portrait: Bool
	let scale: CGFloat
	let height: CGFloat
	@ViewBuilder var content1: () -> Content1
	@ViewBuilder var content2: () -> Content2
	var body: some View {
		GeometryReader { g in //_________portrait___________   ______landscape_____
			let w =  portrait ? g.size.width                 : g.size.width/2/scale
			let h1 = portrait ? min(g.size.height/2, height) : g.size.height/scale
			let h2 = portrait ? g.size.height - h1           : h1
			let dx = portrait ? 0                            : w
			let dy = portrait ? h1                           : 0
			
			ZStack(alignment: .topLeading) {
				VStack {content1(); Spacer() } // JIT init
					.frame(width: w, height: h1)
					
				content2() // JIT init
					.frame(width: w, height: h2)
					.offset(x: dx, y: dy)
			}.scaleEffect(scale, anchor: .topLeading)
			
		}
	}
}
