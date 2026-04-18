import SwiftUI

private struct SkeletonBlock: View {
    let width: CGFloat?
    let height: CGFloat
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: width, height: height)
            .opacity(0.9)
    }
}

struct RemoteFilesLoadingHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    SkeletonBlock(width: 44, height: 16, cornerRadius: 4)
                    SkeletonBlock(width: 68, height: 16, cornerRadius: 4)
                    SkeletonBlock(width: 56, height: 16, cornerRadius: 4)
                }
                .padding(.horizontal, 16)
            }

            HStack {
                SkeletonBlock(width: 64, height: 10, cornerRadius: 4)
                Spacer()
                SkeletonBlock(width: 84, height: 10, cornerRadius: 4)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct RemoteFilesListSkeleton: View {
    var rows: Int = 8

    var body: some View {
        List {
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: 12) {
                    SkeletonBlock(width: 24, height: 24, cornerRadius: 6)

                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: nil, height: 16, cornerRadius: 5)
                        SkeletonBlock(width: CGFloat(120 + (index % 3) * 36), height: 12, cornerRadius: 4)
                    }

                    Spacer()

                    SkeletonBlock(width: 10, height: 14, cornerRadius: 3)
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
    }
}

struct RemoteFilesFolderSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            RemoteFilesLoadingHeader()
            RemoteFilesListSkeleton()
        }
    }
}

struct RemoteEditorSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<18, id: \.self) { index in
                    SkeletonBlock(width: CGFloat(120 + ((index * 37) % 160)), height: 15, cornerRadius: 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

struct RemotePreviewSkeleton: View {
    var body: some View {
        VStack(spacing: 18) {
            SkeletonBlock(width: nil, height: 18, cornerRadius: 5)
            SkeletonBlock(width: nil, height: 420, cornerRadius: 18)
            SkeletonBlock(width: 180, height: 14, cornerRadius: 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }
}
