import SwiftUI
import UIKit

struct AltIcon: Identifiable {
	var displayName: String
	var author: String
	var key: String?
	var image: UIImage
	var id: String { key ?? displayName }

	init(displayName: String, author: String, key: String? = nil) {
		self.displayName = displayName
		self.author = author
		self.key = key
		self.image = AppIconView.loadIcon(key)
	}
}

extension Image {
    func appIconStyle() -> some View {
        self
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .background(Color.white)
            .cornerRadius(13)
            .shadow(radius: 3)
            .padding(8)
    }
}

extension AppIconView {

	static func loadIcon(_ name: String?) -> UIImage {
		if let iconName = name {

			if let path = Bundle.main.path(forResource: iconName, ofType: "png", inDirectory: "AppIcons") {
				if let image = UIImage(contentsOfFile: path) {
					return image
				}
			}

			if let image = UIImage(named: iconName) {
				return image
			}

			let rootPath = Bundle.main.bundleURL.appendingPathComponent("\(iconName).png")
			if let image = UIImage(contentsOfFile: rootPath.path) {
				return image
			}
		}

		if let defaultIcon = UIImage(named: "AppIcon") {
			return defaultIcon
		}
		if let systemIcon = UIImage(systemName: "app") {
			return systemIcon
		}
		return UIImage()
	}

	static func getAllIconsFromFolder() -> [AltIcon] {
		var icons: [AltIcon] = []

		let iconInfo: [String: (displayNameKey: String, authorKey: String)] = [
			"app": ("icon_default", "icon_author"),
			"kana_love": ("icon_love", "icon_author"),
			"kana_peek": ("icon_peek", "icon_author")
		]

		for (key, info) in iconInfo {
			let icon = AltIcon(
				displayName: info.displayNameKey.localized,
				author: info.authorKey.localized,
				key: key
			)

			if !icon.image.isSymbolImage && icon.image.size.width > 1 {
				icons.append(icon)
			}
		}

		return icons
	}
}

struct AppIconView: View {
	@Binding var currentIcon: String?
	@State private var showingSuccess = false
	@State private var isLoading = false

	var allIcons: [AltIcon] {
		let allIcons = AppIconView.getAllIconsFromFolder()

		if !allIcons.isEmpty {
			return allIcons.sorted { icon1, icon2 in
				if icon1.key == "app" { return true }
				if icon2.key == "app" { return false }
				return icon1.key ?? "" < icon2.key ?? ""
			}
		}

		return [
			AltIcon(
				displayName: "icon_default".localized,
				author: "icon_author".localized,
				key: "app"
			),
			AltIcon(
				displayName: "icon_love".localized,
				author: "icon_author".localized,
				key: "kana_love"
			),
			AltIcon(
				displayName: "icon_peek".localized,
				author: "icon_author".localized,
				key: "kana_peek"
			)
		]
	}

	var body: some View {
		ScrollView {
			VStack(spacing: 20) {

				LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
					ForEach(allIcons) { icon in
						_icon(icon: icon)
					}
				}
				.padding(.horizontal, 16)
			}
			.padding(.bottom, 30)
		}
		.navigationTitle("app_icon".localized)
		.onAppear {
			currentIcon = UIApplication.shared.alternateIconName
		}
		.overlay {
			if isLoading {
				ProgressView()
					.background(Color.black.opacity(0.5))
					.ignoresSafeArea()
			}
		}
	}
}

extension AppIconView {
	@ViewBuilder
	private func _icon(
		icon: AltIcon
	) -> some View {
		Button {

			isLoading = true

			let iconNameToSet = icon.key == "app" ? nil : icon.key

			UIApplication.shared.setAlternateIconName(iconNameToSet) { error in
				DispatchQueue.main.async {
					isLoading = false
					currentIcon = UIApplication.shared.alternateIconName
					if error == nil {
						showingSuccess = true
					} else {
						print("❌ [AppIcon] 设置图标失败: \(error!.localizedDescription)")
					}
				}
			}
		} label: {
			VStack(alignment: .center, spacing: 10) {
				ZStack {
					Image(uiImage: icon.image)
						.appIconStyle()
				}

				VStack(alignment: .center, spacing: 2) {
					Text(icon.displayName)
						.font(.system(size: 15, weight: .semibold))
						.multilineTextAlignment(.center)
					Text(icon.author)
						.font(.caption2)
						.foregroundColor(.secondary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity)
			}
		}
		.buttonStyle(.plain)
	}
}
