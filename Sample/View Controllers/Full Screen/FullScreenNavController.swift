//
//  FullScreenNavController.swift
//  PanModalDemo
//
//  Created by Stephen Sowole on 5/2/19.
//  Copyright © 2019 Detail. All rights reserved.
//

import UIKit

final class FullScreenNavController: UINavigationController {

    override func viewDidLoad() {
        super.viewDidLoad()
        pushViewController(FullScreenViewController(), animated: false)
    }
}

extension FullScreenNavController: PanModalPresentable {

    var panScrollable: UIScrollView? {
        return nil
    }

    var verticalOffset: CGFloat {
        return 0.0
    }

    var springDamping: CGFloat {
        return 1.0
    }

    var transitionDuration: Double {
        return 0.4
    }

    var transitionAnimationOptions: UIView.AnimationOptions {
        return [.allowUserInteraction, .beginFromCurrentState]
    }

    var shouldRoundTopCorners: Bool {
        return false
    }

    var showDragIndicator: Bool {
        return false
    }
}

private final class FullScreenViewController: UIViewController {

    let textLabel: UILabel = {
        let label = UILabel()
        label.isOpaque = true
        label.text = "Drag downwards to dismiss"
        label.font = UIFont(name: "Lato-Bold", size: 17)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Full Screen"
        view.isOpaque = true
        view.backgroundColor = .white
        setupConstraints()
    }

    private func setupConstraints() {
        view.addSubview(textLabel)
        textLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        textLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
    }

}
