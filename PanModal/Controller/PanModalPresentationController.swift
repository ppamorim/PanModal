//
//  PanModalPresentationController.swift
//  PanModal
//
//  Copyright © 2019 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 The PanModalPresentationController is the middle layer between the presentingViewController
 and the presentedViewController.
 
 It controls the coordination between the individual transition classes as well as
 provides an abstraction over how the presented view is presented & displayed.
 
 For example, we add a drag indicator view above the presented view and
 a background overlay between the presenting & presented view.
 
 The presented view's layout configuration & presentation is defined using the PanModalPresentable.
 
 By conforming to the PanModalPresentable protocol & overriding values
 the presented view can define its layout configuration & presentation.
 */
open class PanModalPresentationController: UIPresentationController {

    /**
     Enum representing the possible presentation states
     */
    public enum PresentationState {
        case shortForm
        case longForm
    }

    /**
     Constants
     */
    struct Constants {
        static let indicatorOffset = CGFloat(8.0)
        static let snapMovementSensitivity = CGFloat(0.7)
        static let dragIndicatorSize = CGSize(width: 36.0, height: 5.0)
    }

    // MARK: - Properties

    /**
     A flag to track if the presented view is animating
     */
    private var isPresentedViewAnimating = false

    /**
     A flag to determine if scrolling should seamlessly transition
     from the pan modal container view to the scroll view
     once the scroll limit has been reached.
     */
    private var extendsPanScrolling = true

    /**
     A flag to determine if scrolling should be limited to the longFormHeight.
     Return false to cap scrolling at .max height.
     */
    private var anchorModalToLongForm = true

    /**
     The y content offset value of the embedded scroll view
     */
    private var scrollViewYOffset: CGFloat = 0.0

    /**
     An observer for the scroll view content offset
     */
    private var scrollObserver: NSKeyValueObservation?

    // store the y positions so we don't have to keep re-calculating

    /**
     The y value for the short form presentation state
     */
    private var shortFormPosition: CGFloat = 0

    /**
     The y value for the long form presentation state
     */
    private var longFormPosition: CGFloat = 0

    /**
     Determine anchored X postion based on the `anchorModalToLongForm` flag
     */
    private var anchoredHorizontalPosition: CGFloat {
        anchorModalToLongForm
        ? longFormPosition
        : (presentable?.horizontalOffset ?? 0)
    }

    /**
     Determine anchored Y postion based on the `anchorModalToLongForm` flag
     */
    private var anchoredVerticalPosition: CGFloat {
        anchorModalToLongForm
        ? longFormPosition
        : (presentable?.verticalOffset ?? 0)
    }

    /**
     Configuration object for PanModalPresentationController
     */
    private var presentable: PanModalPresentable? {
        presentedViewController as? PanModalPresentable
    }

    // MARK: - Views

    /**
     Background view used as an overlay over the presenting view
     */
    private lazy var backgroundView: DimmedView = {
        let view: DimmedView
        if let color = presentable?.panModalBackgroundColor {
            view = DimmedView(dimColor: color)
        } else {
            view = DimmedView()
        }
        view.didTap = { [weak self] _ in
            if self?.presentable?.allowsTapToDismiss == true {
                self?.presentedViewController.dismiss(animated: true)
            }
        }
        return view
    }()

    /**
     A wrapper around the presented view so that we can modify
     the presented view apperance without changing
     the presented view's properties
     */
    private lazy var panContainerView: PanContainerView = {
        let view = PanContainerView(
            presentedView: presentedViewController.view,
            frame: containerView?.frame ?? .zero
        )
        view.backgroundColor = UIColor.red
        view.isOpaque = false
        return view
    }()

    /**
     Drag Indicator View
     */
    private lazy var dragIndicatorView: UIView = {
        let view: UIView = UIView()
        view.backgroundColor = presentable?.dragIndicatorBackgroundColor
        var alpha: CGFloat = 1.0
        view.backgroundColor?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        view.isOpaque = alpha == 1.0
        view.layer.cornerRadius = Constants.dragIndicatorSize.height / 2.0
        if #available(iOS 13.0, *) {
            view.layer.cornerCurve = .continuous
        }
        return view
    }()

    /**
     Override presented view to return the pan container wrapper
     */
    public override var presentedView: UIView {
        panContainerView
    }

    // MARK: - Gesture Recognizers

    /**
     Gesture recognizer to detect & track pan gestures
     */
    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(didPanOnPresentedView(_ :))
        )
        gesture.minimumNumberOfTouches = 1
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = self
        return gesture
    }()

    /**
     Flag used to detect when the PanModal is being either dismissed
     by swiping it down or by calling the function `dismiss(_)`.
     */
    private var dismissFromGestureRecognizer: Bool = false

    // MARK: - Deinitializers

    deinit {
        scrollObserver?.invalidate()
    }

    // MARK: - Lifecycle

    override public func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
    }

    override public func presentationTransitionWillBegin() {

        guard let containerView = self.containerView else {
            return
        }

        // Fix bug issue https://github.com/slackhq/PanModal/issues/202#issuecomment-1792448924
        if self.panContainerView.frame == .zero {
            self.adjustPresentedViewFrame()
        }

        layoutBackgroundView(in: containerView)
        layoutPresentedView(in: containerView)
        adjustPresentedViewFrame()
        configureScrollViewInsets()

        guard let coordinator = presentedViewController.transitionCoordinator else {
            backgroundView.dimState = .max
            return
        }

        containerView.setNeedsLayout()
        containerView.layoutIfNeeded()

        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.adjustPresentedViewFrame()
            self?.backgroundView.dimState = .max
            self?.dragIndicatorView.layoutIfNeeded()
            self?.presentedViewController.setNeedsStatusBarAppearanceUpdate()
        })
    }

    override public func presentationTransitionDidEnd(_ completed: Bool) {
        if completed {
            return
        }
        backgroundView.removeFromSuperview()
    }

    override public func dismissalTransitionWillBegin() {
        presentable?.panModalWillDismiss(fromGestureRecognizer: dismissFromGestureRecognizer)

        guard let coordinator = presentedViewController.transitionCoordinator else {
            backgroundView.dimState = .off
            return
        }

        /**
         Drag indicator is drawn outside of view bounds
         so hiding it on view dismiss means avoiding visual bugs
         */
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.dragIndicatorView.alpha = 0.0
            self?.backgroundView.dimState = .off
            self?.presentingViewController.setNeedsStatusBarAppearanceUpdate()
        })
    }

    override public func dismissalTransitionDidEnd(_ completed: Bool) {
        if !completed {
            return
        }
        presentable?.panModalDidDismiss(fromGestureRecognizer: dismissFromGestureRecognizer)
    }

    /**
     Update presented view size in response to size class changes
     */
    override public func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard
                let self = self,
                let presentable = self.presentable
            else { return }

            self.adjustPresentedViewFrame()
            if presentable.shouldRoundTopCorners {
                self.addRoundedCorners(to: self.presentedView)
            }
        })
    }

}

// MARK: - Public Methods

public extension PanModalPresentationController {

    /**
     Transition the PanModalPresentationController
     to the given presentation state
     */
    func transition(to state: PresentationState) {

        guard presentable?.shouldTransition(to: state) == true
        else { return }

        presentable?.willTransition(to: state)

        switch state {
        case .shortForm:
            snap(to: shortFormPosition)
        case .longForm:
            snap(to: longFormPosition)
        }
    }

    /**
     Operations on the scroll view, such as content height changes,
     or when inserting/deleting rows can cause the pan modal to jump,
     caused by the pan modal responding to content offset changes.
     
     To avoid this, you can call this method to perform scroll view updates,
     with scroll observation temporarily disabled.
     */
    func performUpdates(_ updates: () -> Void) {

        guard let scrollView: UIScrollView = presentable?.panScrollable
        else { return }

        // Pause scroll observer
        scrollObserver?.invalidate()
        scrollObserver = nil

        // Perform updates
        updates()

        // Resume scroll observer
        trackScrolling(scrollView)
        observe(scrollView: scrollView)
    }

    /**
     Updates the PanModalPresentationController layout
     based on values in the PanModalPresentable
     
     - Note: This should be called whenever any
     pan modal presentable value changes after the initial presentation
     */
    func setNeedsLayoutUpdate() {
        configureViewLayout()
        adjustPresentedViewFrame()
        observe(scrollView: presentable?.panScrollable)
        configureScrollViewInsets()
    }

}

// MARK: - Presented View Layout Configuration

private extension PanModalPresentationController {

    /**
     Boolean flag to determine if the presented view is anchored
     */
    var isPresentedViewAnchored: Bool {

        guard !isPresentedViewAnimating && extendsPanScrolling else {
            return false
        }

        if presentable?.orientation == .horizontal && presentedView.frame.minX.rounded() <= anchoredHorizontalPosition.rounded() {
            return true
        }
        if presentable?.orientation == .vertical && presentedView.frame.minY.rounded() <= anchoredVerticalPosition.rounded() {
            return true
        }

        return false
    }

    /**
     Adds the presented view to the given container view
     & configures the view elements such as drag indicator, rounded corners
     based on the pan modal presentable.
     */
    func layoutPresentedView(in containerView: UIView) {

        /**
         If the presented view controller does not conform to pan modal presentable
         don't configure
         */
        guard let presentable = presentable
        else { return }

        /**
         ⚠️ If this class is NOT used in conjunction with the PanModalPresentationAnimator
         & PanModalPresentable, the presented view should be added to the container view
         in the presentation animator instead of here
         */
        containerView.addSubview(presentedView)
        containerView.addGestureRecognizer(panGestureRecognizer)

        if presentable.shouldRoundTopCorners {
            addRoundedCorners(to: presentedView)
        }

        if presentable.showDragIndicator {
            addDragIndicatorView(to: containerView, on: presentedView)
        }

        setNeedsLayoutUpdate()
        adjustPanContainerBackgroundColor()
    }

    /**
     Reduce height of presentedView so that it sits at the bottom of the screen
     */
    func adjustPresentedViewFrame() {

        guard let containerViewFrame: CGRect = containerView?.frame else {
            return
        }

        let adjustedSize: CGSize
        if self.presentable?.orientation == .vertical {
            let horizontalOffset: CGFloat = presentable?.horizontalOffset ?? 0.0
            adjustedSize = CGSize(
                width: containerViewFrame.size.width - horizontalOffset,
                height: containerViewFrame.size.height - self.anchoredVerticalPosition
            )
            panContainerView.frame.origin.x = horizontalOffset/2.0
        } else {
            let verticalOffset: CGFloat = presentable?.verticalOffset ?? 0.0
            adjustedSize = CGSize(
                width: containerViewFrame.size.width - self.anchoredHorizontalPosition,
                height: containerViewFrame.size.height - verticalOffset
            )
            panContainerView.frame.origin.y = verticalOffset/2.0
        }

        panContainerView.frame.size = adjustedSize

        if self.presentable?.orientation == .vertical {
            if ![shortFormPosition, longFormPosition].contains(panContainerView.frame.origin.y) {
                // if the container is already in the correct position, no need to adjust positioning
                // (rotations & size changes cause positioning to be out of sync)
                let yPosition = panContainerView.frame.origin.y - panContainerView.frame.height + containerViewFrame.height
                presentedView.frame.origin.y = max(yPosition, anchoredVerticalPosition)
                //                dragIndicatorView.frame.origin.y = presentedView.frame.origin.y - Constants.indicatorOffset
                //              print("presentedView.frame.origin.y2 \(presentedView.frame.origin.y)")
            }
        } else {
            if ![shortFormPosition, longFormPosition].contains(panContainerView.frame.origin.x) {
                // if the container is already in the correct position, no need to adjust positioning
                // (rotations & size changes cause positioning to be out of sync)
                let xPosition = panContainerView.frame.origin.x - panContainerView.frame.width + containerViewFrame.width
                presentedView.frame.origin.x = max(xPosition, anchoredHorizontalPosition)
                dragIndicatorView.frame.origin.x = presentedView.frame.origin.x - Constants.indicatorOffset
            }
        }

        presentedViewController.view.frame = CGRect(
            origin: .zero,
            size: panContainerView.frame.size
        )
        presentedViewController.view.layoutIfNeeded()

    }

    /**
     Adds a background color to the pan container view
     in order to avoid a gap at the bottom
     during initial view presentation in longForm (when view bounces)
     */
    func adjustPanContainerBackgroundColor() {
        //        panContainerView.backgroundColor = presentedViewController.view.backgroundColor
        //            ?? presentable?.panScrollable?.backgroundColor
    }

    /**
     Adds the background view to the view hierarchy
     & configures its layout constraints.
     */
    func layoutBackgroundView(in containerView: UIView) {
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(backgroundView)
        backgroundView.topAnchor.constraint(equalTo: containerView.topAnchor).isActive = true
        backgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor).isActive = true
        backgroundView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor).isActive = true
        backgroundView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor).isActive = true
    }

    /**
     Adds the drag indicator view to the view hierarchy
     & configures its layout constraints.
     */
    func addDragIndicatorView(to view: UIView, on pinEdgeView: UIView) {
        dragIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dragIndicatorView)
        if presentable?.orientation == .vertical {
            dragIndicatorView.bottomAnchor.constraint(equalTo: pinEdgeView.topAnchor, constant: -Constants.indicatorOffset).isActive = true
            dragIndicatorView.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
            dragIndicatorView.widthAnchor.constraint(equalToConstant: Constants.dragIndicatorSize.width).isActive = true
            dragIndicatorView.heightAnchor.constraint(equalToConstant: Constants.dragIndicatorSize.height).isActive = true
            return
        }
        dragIndicatorView.trailingAnchor.constraint(equalTo: pinEdgeView.leadingAnchor, constant: -Constants.indicatorOffset).isActive = true
        dragIndicatorView.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        dragIndicatorView.widthAnchor.constraint(equalToConstant: Constants.dragIndicatorSize.height).isActive = true
        dragIndicatorView.heightAnchor.constraint(equalToConstant: Constants.dragIndicatorSize.width).isActive = true
    }

    /**
     Calculates & stores the layout anchor points & options
     */
    func configureViewLayout() {

        guard let layoutPresentable = presentedViewController as? PanModalPresentable.LayoutType else {
            return
        }

        shortFormPosition = layoutPresentable.shortFormPosition
        longFormPosition = layoutPresentable.longFormPosition
        anchorModalToLongForm = layoutPresentable.anchorModalToLongForm
        extendsPanScrolling = layoutPresentable.allowsExtendedPanScrolling

        containerView?.isUserInteractionEnabled = layoutPresentable.isUserInteractionEnabled
    }

    /**
     Configures the scroll view insets
     */
    func configureScrollViewInsets() {

        guard
            let scrollView = presentable?.panScrollable,
            !scrollView.isScrolling
        else { return }

        /**
         Disable vertical scroll indicator until we start to scroll
         to avoid visual bugs
         */
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollIndicatorInsets = presentable?.scrollIndicatorInsets ?? .zero

        /**
         Set the appropriate contentInset as the configuration within this class
         offsets it
         */
        if #available(iOS 11.0, *) {
            scrollView.contentInset.bottom = presentingViewController.view.safeAreaInsets.bottom
        } else {
            scrollView.contentInset.bottom = presentingViewController.bottomLayoutGuide.length
        }

        /**
         As we adjust the bounds during `handleScrollViewTopBounce`
         we should assume that contentInsetAdjustmentBehavior will not be correct
         */
        if #available(iOS 11.0, *) {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
    }

}

// MARK: - Pan Gesture Event Handler

private extension PanModalPresentationController {

    /**
     The designated function for handling pan gesture events
     */
    @objc func didPanOnPresentedView(_ recognizer: UIPanGestureRecognizer) {

        guard
            shouldRespond(to: recognizer),
            let containerView = containerView
        else {
            recognizer.setTranslation(.zero, in: recognizer.view)
            return
        }

        switch recognizer.state {
        case .began, .changed:

            /**
             Respond accordingly to pan gesture translation
             */
            respond(to: recognizer)

            if self.presentable?.orientation == .horizontal {

                /**
                 If presentedView is translated above the longForm threshold, treat as transition
                 */
                if presentedView.frame.origin.x == anchoredHorizontalPosition && extendsPanScrolling {
                    presentable?.willTransition(to: .longForm)
                }

            } else {

                /**
                 If presentedView is translated above the longForm threshold, treat as transition
                 */
                if presentedView.frame.origin.y == anchoredVerticalPosition && extendsPanScrolling {
                    presentable?.willTransition(to: .longForm)
                }

            }

        default:

            /**
             Use velocity sensitivity value to restrict snapping
             */
            let velocity = recognizer.velocity(in: presentedView)

            if self.presentable?.orientation == .vertical {

                if isVelocityWithinSensitivityRange(velocity.y) {

                    /**
                     If velocity is within the sensitivity range,
                     transition to a presentation state or dismiss entirely.
                     
                     This allows the user to dismiss directly from long form
                     instead of going to the short form state first.
                     */
                    if velocity.y < 0 {
                        transition(to: .longForm)
                    } else if
                        (nearest(to: presentedView.frame.minY, inValues: [longFormPosition, containerView.bounds.height]) == longFormPosition
                         && presentedView.frame.minY < shortFormPosition) || presentable?.allowsDragToDismiss == false
                            && presentable?.shouldDismissWhenLongForm == false {
                        transition(to: .shortForm)

                    } else {
                        dismissFromGestureRecognizer = true
                        presentedViewController.dismiss(animated: true)
                    }

                } else {

                    /**
                     The `containerView.bounds.height` is used to determine
                     how close the presented view is to the bottom of the screen
                     */
                    let position = nearest(to: presentedView.frame.minY, inValues: [containerView.bounds.height, shortFormPosition, longFormPosition])

                    if position == longFormPosition {
                        transition(to: .longForm)

                    } else if position == shortFormPosition || presentable?.allowsDragToDismiss == false {
                        transition(to: .shortForm)

                    } else {
                        dismissFromGestureRecognizer = true
                        presentedViewController.dismiss(animated: true)
                    }

                }
                return
            }

            if isVelocityWithinSensitivityRange(velocity.x) {

                if velocity.x < 0 {
                    transition(to: .longForm)
                } else if
                    (nearest(to: presentedView.frame.minX, inValues: [longFormPosition, containerView.bounds.width]) == longFormPosition
                     && presentedView.frame.minX < shortFormPosition) || presentable?.allowsDragToDismiss == false
                        && presentable?.shouldDismissWhenLongForm == false {
                    transition(to: .shortForm)

                } else {
                    dismissFromGestureRecognizer = true
                    presentedViewController.dismiss(animated: true)
                }

            } else {

                /**
                 The `containerView.bounds.height` is used to determine
                 how close the presented view is to the bottom of the screen
                 */
                let position = nearest(to: presentedView.frame.minX, inValues: [containerView.bounds.width, shortFormPosition, longFormPosition])

                if position == longFormPosition {
                    transition(to: .longForm)

                } else if position == shortFormPosition || presentable?.allowsDragToDismiss == false {
                    transition(to: .shortForm)

                } else {
                    dismissFromGestureRecognizer = true
                    presentedViewController.dismiss(animated: true)
                }

            }

        }

    }

    /**
     Determine if the pan modal should respond to the gesture recognizer.
     
     If the pan modal is already being dragged & the delegate returns false, ignore until
     the recognizer is back to it's original state (.began)
     
     ⚠️ This is the only time we should be cancelling the pan modal gesture recognizer
     */
    func shouldRespond(to panGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        guard
            presentable?.shouldRespond(to: panGestureRecognizer) == true ||
                !(panGestureRecognizer.state == .began || panGestureRecognizer.state == .cancelled)
        else {
            panGestureRecognizer.isEnabled = false
            panGestureRecognizer.isEnabled = true
            return false
        }
        return !shouldFail(panGestureRecognizer: panGestureRecognizer)
    }

    /**
     Communicate intentions to presentable and adjust subviews in containerView
     */
    func respond(to panGestureRecognizer: UIPanGestureRecognizer) {
        presentable?.willRespond(to: panGestureRecognizer)

        if self.presentable?.orientation == .vertical {

            var yDisplacement: CGFloat = panGestureRecognizer.translation(in: presentedView).y

            /**
             If the presentedView is not anchored to long form, reduce the rate of movement
             above the threshold
             */
            if presentedView.frame.origin.y < longFormPosition {
                yDisplacement /= 2.0
            }
            adjust(to: presentedView.frame.origin.y + yDisplacement)

            panGestureRecognizer.setTranslation(.zero, in: presentedView)

            return
        }

        var xDisplacement: CGFloat = panGestureRecognizer.translation(in: presentedView).x

        /**
         If the presentedView is not anchored to long form, reduce the rate of movement
         above the threshold
         */
        if presentedView.frame.origin.x < longFormPosition {
            xDisplacement /= 2.0
        }
        adjust(to: presentedView.frame.origin.x + xDisplacement)

        panGestureRecognizer.setTranslation(.zero, in: presentedView)

    }

    /**
     Determines if we should fail the gesture recognizer based on certain conditions
     
     We fail the presented view's pan gesture recognizer if we are actively scrolling on the scroll view.
     This allows the user to drag whole view controller from outside scrollView touch area.
     
     Unfortunately, cancelling a gestureRecognizer means that we lose the effect of transition scrolling
     from one view to another in the same pan gesture so don't cancel
     */
    func shouldFail(panGestureRecognizer: UIPanGestureRecognizer) -> Bool {

        /**
         Allow api consumers to override the internal conditions &
         decide if the pan gesture recognizer should be prioritized.
         
         ⚠️ This is the only time we should be cancelling the panScrollable recognizer,
         for the purpose of ensuring we're no longer tracking the scrollView
         */
        guard !shouldPrioritize(panGestureRecognizer: panGestureRecognizer) else {
            presentable?.panScrollable?.panGestureRecognizer.isEnabled = false
            presentable?.panScrollable?.panGestureRecognizer.isEnabled = true
            return false
        }

        guard
            isPresentedViewAnchored,
            let scrollView: UIScrollView = presentable?.panScrollable,
            scrollView.contentOffset.y > -scrollView.contentInset.top
        else {
            return false
        }

        let loc = panGestureRecognizer.location(in: presentedView)
        return (scrollView.frame.contains(loc) || scrollView.isScrolling)
    }

    /**
     Determine if the presented view's panGestureRecognizer should be prioritized over
     embedded scrollView's panGestureRecognizer.
     */
    func shouldPrioritize(panGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        panGestureRecognizer.state == .began &&
        presentable?.shouldPrioritize(panModalGestureRecognizer: panGestureRecognizer) == true
    }

    /**
     Check if the given velocity is within the sensitivity range
     */
    func isVelocityWithinSensitivityRange(_ velocity: CGFloat) -> Bool {
        (abs(velocity) - (1000 * (1 - Constants.snapMovementSensitivity))) > 0
    }

    func snap(to position: CGFloat) {
        PanModalAnimator.animate({ [weak self] in
            self?.adjust(to: position, updateDragIndicatorView: true)
            self?.isPresentedViewAnimating = true
        }, config: presentable) { [weak self] didComplete in
            self?.adjust(to: position, updateDragIndicatorView: true)
            self?.isPresentedViewAnimating = !didComplete
        }
    }

    /**
     Sets the y position of the presentedView & adjusts the backgroundView.
     */
    func adjust(to position: CGFloat, updateDragIndicatorView: Bool = false) {

        if self.presentable?.orientation == .vertical {

            presentedView.frame.origin.y = max(position, anchoredVerticalPosition)
            if updateDragIndicatorView {
                dragIndicatorView.frame.origin.y = presentedView.frame.origin.y - Constants.indicatorOffset
            }

            guard presentedView.frame.origin.y > shortFormPosition else {
                backgroundView.dimState = .max
                return
            }

            let yDisplacementFromShortForm: CGFloat = presentedView.frame.origin.y - shortFormPosition

            backgroundView.dimState = .percent(1.0 - (yDisplacementFromShortForm / presentedView.frame.height))

            return
        }

        presentedView.frame.origin.x = max(position, anchoredHorizontalPosition)

        if updateDragIndicatorView {
            dragIndicatorView.frame.origin.x = presentedView.frame.origin.x - Constants.indicatorOffset
        }

        guard presentedView.frame.origin.x > shortFormPosition else {
            backgroundView.dimState = .max
            return
        }

        let xDisplacementFromShortForm: CGFloat = presentedView.frame.origin.x - shortFormPosition

        /**
         Once presentedView is translated below shortForm, calculate yPos relative to bottom of screen
         and apply percentage to backgroundView alpha
         */
        backgroundView.dimState = .percent(1.0 - (xDisplacementFromShortForm / presentedView.frame.width))
    }

    /**
     Finds the nearest value to a given number out of a given array of float values
     
     - Parameters:
     - number: reference float we are trying to find the closest value to
     - values: array of floats we would like to compare against
     */
    func nearest(to number: CGFloat, inValues values: [CGFloat]) -> CGFloat {
        guard let nearestVal: CGFloat = values.min(by: { abs(number - $0) < abs(number - $1) })
        else { return number }
        return nearestVal
    }
}

// MARK: - UIScrollView Observer

private extension PanModalPresentationController {

    /**
     Creates & stores an observer on the given scroll view's content offset.
     This allows us to track scrolling without overriding the scrollView delegate
     */
    func observe(scrollView: UIScrollView?) {
        scrollObserver?.invalidate()
        scrollObserver = scrollView?.observe(\.contentOffset, options: .old) { [weak self] scrollView, change in

            /**
             Incase we have a situation where we have two containerViews in the same presentation
             */
            guard self?.containerView != nil
            else { return }

            self?.didPanOnScrollView(scrollView, change: change)
        }
    }

    /**
     Scroll view content offset change event handler
     
     Also when scrollView is scrolled to the top, we disable the scroll indicator
     otherwise glitchy behaviour occurs
     
     This is also shown in Apple Maps (reverse engineering)
     which allows us to seamlessly transition scrolling from the panContainerView to the scrollView
     */
    func didPanOnScrollView(_ scrollView: UIScrollView, change: NSKeyValueObservedChange<CGPoint>) {

        guard
            !presentedViewController.isBeingDismissed,
            !presentedViewController.isBeingPresented
        else { return }

        if !isPresentedViewAnchored && scrollView.contentOffset.y > -scrollView.contentInset.top {

            /**
             Hold the scrollView in place if we're actively scrolling and not handling top bounce
             */
            haltScrolling(scrollView)

        } else if scrollView.isScrolling || isPresentedViewAnimating {

            if isPresentedViewAnchored {
                /**
                 While we're scrolling upwards on the scrollView,
                 store the last content offset position
                 */
                trackScrolling(scrollView)
            } else {
                /**
                 Keep scroll view in place while we're panning on main view
                 */
                haltScrolling(scrollView)
            }

        } else if presentedViewController.view.isKind(of: UIScrollView.self)
                    && !isPresentedViewAnimating
                    && scrollView.contentOffset.y <= -scrollView.contentInset.top {

            /**
             In the case where we drag down quickly on the scroll view and let go,
             `handleScrollViewTopBounce` adds a nice elegant touch.
             */
            handleScrollViewTopBounce(scrollView: scrollView, change: change)
        } else {
            trackScrolling(scrollView)
        }
    }

    /**
     Halts the scroll of a given scroll view & anchors it at the `scrollViewYOffset`
     */
    func haltScrolling(_ scrollView: UIScrollView) {
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollViewYOffset - scrollView.contentInset.top), animated: false)
        scrollView.showsVerticalScrollIndicator = false
    }

    /**
     As the user scrolls, track & save the scroll view y offset.
     This helps halt scrolling when we want to hold the scroll view in place.
     */
    func trackScrolling(_ scrollView: UIScrollView) {
        scrollViewYOffset = max(scrollView.contentOffset.y, 0.0)
        scrollView.showsVerticalScrollIndicator = true
    }

    /**
     To ensure that the scroll transition between the scrollView & the modal
     is completely seamless, we need to handle the case where content offset is negative.
     
     In this case, we follow the curve of the decelerating scroll view.
     This gives the effect that the modal view and the scroll view are one view entirely.
     
     - Note: This works best where the view behind view controller is a UIScrollView.
     So, for example, a UITableViewController.
     */
    func handleScrollViewTopBounce(scrollView: UIScrollView, change: NSKeyValueObservedChange<CGPoint>) {

        guard let oldYValue = change.oldValue?.y, scrollView.isDecelerating
        else { return }

        let yOffset = scrollView.contentOffset.y
        let presentedSize = containerView?.frame.size ?? .zero

        /**
         Decrease the view bounds by the y offset so the scroll view stays in place
         and we can still get updates on its content offset
         */
        presentedView.bounds.size = CGSize(width: presentedSize.width, height: presentedSize.height + yOffset)

        if oldYValue > yOffset {
            /**
             Move the view in the opposite direction to the decreasing bounds
             until half way through the deceleration so that it appears
             as if we're transferring the scrollView drag momentum to the entire view
             */
            presentedView.frame.origin.y = longFormPosition - yOffset
        } else {
            scrollViewYOffset = 0
            snap(to: longFormPosition)
        }

        scrollView.showsVerticalScrollIndicator = false
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PanModalPresentationController: UIGestureRecognizerDelegate {

    /**
     Do not require any other gesture recognizers to fail
     */
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    /**
     Allow simultaneous gesture recognizers only when the other gesture recognizer's view
     is the pan scrollable view
     */
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer.view == presentable?.panScrollable
    }
}

// MARK: - UIBezierPath

private extension PanModalPresentationController {

    /**
     Draws top rounded corners on a given view
     We have to set a custom path for corner rounding
     because we render the dragIndicator outside of view bounds
     */
    func addRoundedCorners(to view: UIView) {
        let radius = presentable?.cornerRadius ?? 0

        if radius == 0 {
            // In case removing the radius
            view.layer.cornerRadius = 0
            view.layer.masksToBounds = false
            return
        }

        view.layer.cornerRadius = radius
        view.layer.masksToBounds = true

        if #available(iOS 11.0, *) {
            let maskedCorners: CACornerMask = CACornerMask(
                rawValue: createMask(
                    corners: self.presentable?.orientation == .vertical
                    ? [.topLeft, .topRight]
                    : [.topLeft, .bottomLeft]
                )
            )
            view.layer.maskedCorners = maskedCorners
            if #available(iOS 13.0, *) {
                view.layer.cornerCurve = .continuous
            }
        }

    }

    enum Corner: Int {
        case bottomRight = 0,
             topRight,
             bottomLeft,
             topLeft
    }

    @available(iOS 11.0, *)
    private func parseCorner(corner: Corner) -> CACornerMask.Element {
        let corners: [CACornerMask.Element] = [
            .layerMaxXMaxYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMinXMinYCorner
        ]
        return corners[corner.rawValue]
    }

    @available(iOS 11.0, *)
    private func createMask(corners: [Corner]) -> UInt {
        corners.reduce(0, { (a, b) -> UInt in a + parseCorner(corner: b).rawValue })
    }

}

// MARK: - Helper Extensions

private extension UIScrollView {

    /**
     A flag to determine if a scroll view is scrolling
     */
    var isScrolling: Bool {
        return isDragging && !isDecelerating || isTracking
    }
}
#endif
