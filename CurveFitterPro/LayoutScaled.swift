//
//  LayoutScaled.swift
//
//  Created by Joseph Levy on 6/5/26.
//
import SwiftUI
extension View {
	public func layoutScaled(by scale: CGFloat) -> some View {
		GeometryReader { geometry in // Fills the available space
			self
				.scaleEffect(scale, anchor: .topLeading)
				.frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
		}
	}
	
	public func scaleToFitAvailableSize(minSize: CGSize) -> some View {
		GeometryReader { geo in
			let size = CGSize(width: min(minSize.width, geo.size.width), height: min(minSize.height, geo.size.height))
			let scale = min(geo.size.width / size.width, geo.size.height / size.height) // ,1 is redundant
			self
				.layoutScaled(by: 1/scale)
		}
	}
}
