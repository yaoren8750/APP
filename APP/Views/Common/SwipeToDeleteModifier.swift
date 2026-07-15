import SwiftUI

struct SwipeAction {
    let title: String
    let systemImage: String
    let backgroundColor: Color
    let action: () -> Void
}

struct SwipeActionsModifier: ViewModifier {
    var actions: [SwipeAction]
    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    
    private var totalButtonWidth: CGFloat {
        CGFloat(actions.count) * 80
    }
    private let maxSwipeDistance: CGFloat = 200
    
    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            actionButtons
            
            content
                .offset(x: offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.width < 0 {
                                isDragging = true
                                let dragAmount = -value.translation.width
                                let resistance: CGFloat = dragAmount > totalButtonWidth ? 0.3 : 1.0
                                offset = -min(dragAmount * resistance, maxSwipeDistance)
                            } else if isDragging {
                                offset = min(value.translation.width * 0.5, 0)
                            }
                        }
                        .onEnded { value in
                            isDragging = false
                            let dragAmount = -value.translation.width
                            
                            if dragAmount > totalButtonWidth * 0.4 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    offset = -totalButtonWidth
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    offset = 0
                                }
                            }
                        }
                )
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 0) {
            Spacer()
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        offset = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        action.action()
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                        Text(action.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .frame(width: 80)
                .background(action.backgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func swipeActions(_ actions: [SwipeAction]) -> some View {
        modifier(SwipeActionsModifier(actions: actions))
    }
}
