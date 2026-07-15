import SwiftUI
import UIKit

struct ColorPickerView: UIViewControllerRepresentable {
    @Binding var selectedColor: Color
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let colorPicker = UIColorPickerViewController()
        colorPicker.selectedColor = UIColor(selectedColor)
        colorPicker.supportsAlpha = false
        colorPicker.delegate = context.coordinator

        let navController = UINavigationController(rootViewController: colorPicker)
        navController.navigationBar.prefersLargeTitles = false

        return navController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        if let colorPicker = uiViewController.viewControllers.first as? UIColorPickerViewController {
            colorPicker.selectedColor = UIColor(selectedColor)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: ColorPickerView

        init(_ parent: ColorPickerView) {
            self.parent = parent
        }

        func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
            parent.selectedColor = Color(uiColor: viewController.selectedColor)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.dismiss()
        }
    }
}
