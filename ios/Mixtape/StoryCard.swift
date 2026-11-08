import SwiftUI
import UIKit

// MARK: - Carte pour story Instagram

enum StoryStyle: String, CaseIterable, Identifiable {
    case cover, full, note
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cover: return "Pochette"
        case .full: return "Plein cadre"
        case .note: return "Annotation"
        }
    }
}

/// L'image de la story, en 1080 × 1920.
private struct StoryCardView: View {
    let style: StoryStyle
    let track: Track
    let cover: UIImage?
    let tint: Color
    let page: Color
    let note: Annotation?

    private var coverImage: some View {
        Group {
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [tint, page], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    var body: some View {
        ZStack {
            switch style {
            case .cover:
                LinearGradient(colors: [tint, page], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    Spacer()
                    coverImage
                        .frame(width: 780, height: 780)
                        .clipShape(RoundedRectangle(cornerRadius: 36))
                        .shadow(color: .black.opacity(0.45), radius: 50, y: 30)
                    Text(track.title)
                        .font(.system(size: 76, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .padding(.top, 80)
                        .padding(.horizontal, 90)
                    Text(track.displayArtist)
                        .font(.system(size: 50, weight: .semibold))
                        .opacity(0.75)
                        .padding(.top, 14)
                    Capsule().fill(.white.opacity(0.3))
                        .frame(width: 640, height: 10)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 260, height: 10) }
                        .padding(.top, 60)
                    Spacer()
                    footer
                }
            case .full:
                coverImage.frame(width: 1080, height: 1920).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    Spacer()
                    Text("EN BOUCLE")
                        .font(.system(size: 38, weight: .heavy))
                        .tracking(6)
                        .opacity(0.85)
                    Text(track.title)
                        .font(.system(size: 110, weight: .black))
                        .lineLimit(2)
                        .minimumScaleFactor(0.4)
                    Text(track.displayArtist)
                        .font(.system(size: 56, weight: .semibold))
                        .opacity(0.8)
                    footer.padding(.top, 70)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 90)
            case .note:
                Color(white: 0.06)
                LinearGradient(colors: [tint.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    if let note {
                        Text("\(formatTime(note.start)) · MON PASSAGE")
                            .font(.system(size: 40, weight: .heavy))
                            .tracking(4)
                            .foregroundStyle(Color.accentPink)
                        Text("« \(note.text) »")
                            .font(.system(size: 72, weight: .bold))
                            .lineLimit(9)
                            .minimumScaleFactor(0.4)
                            .padding(.top, 30)
                    }
                    HStack(spacing: 30) {
                        coverImage
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(track.title).font(.system(size: 52, weight: .bold)).lineLimit(2)
                            Text(track.displayArtist).font(.system(size: 40, weight: .medium)).opacity(0.7)
                        }
                    }
                    .padding(.top, 90)
                    Spacer()
                    footer
                }
                .padding(.horizontal, 90)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 1080, height: 1920)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note")
            Text("écouté sur Mixtape")
        }
        .font(.system(size: 34, weight: .semibold))
        .opacity(0.6)
        .frame(maxWidth: .infinity, alignment: style == .full ? .leading : .center)
        .padding(.bottom, 120)
    }
}

/// Fiche « Carte pour story » : choix du style, aperçu, partage.
struct StoryCardSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var notes = AnnotationStore.shared
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var style: StoryStyle = .cover
    @State private var cover: UIImage?
    @State private var tint: Color = Color(white: 0.3)
    @State private var page: Color = Color(white: 0.08)
    @State private var rendered: UIImage?

    private var note: Annotation? { notes.notes(for: track.id).first }
    private var styles: [StoryStyle] { note == nil ? [.cover, .full] : StoryStyle.allCases }

    private var card: StoryCardView {
        StoryCardView(style: style, track: track, cover: cover, tint: tint, page: page, note: note)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Picker("Style", selection: $style) {
                    ForEach(styles) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                GeometryReader { geo in
                    let scale = min(geo.size.width / 1080, geo.size.height / 1920)
                    card
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: 1080 * scale, height: 1920 * scale, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 30)

                if let rendered {
                    ShareLink(item: Image(uiImage: rendered),
                              preview: SharePreview(track.title, image: Image(uiImage: rendered))) {
                        Label("Partager en story", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.accentPink, in: Capsule())
                    }
                    .padding(.horizontal, 20)
                } else {
                    ProgressView().frame(height: 50)
                }
                Text("Choisis Instagram, puis « Story ». Ou « Enregistrer l'image » pour la poster plus tard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .padding(.vertical, 12)
            .navigationTitle("Carte pour story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() } }
            }
            .task {
                if let url = library.coverURL(track), let img = await ImageLoader.shared.image(for: url) {
                    cover = img
                    tint = ArtworkColor.average(of: img) ?? tint
                    page = ArtworkColor.background(of: img) ?? page
                }
                render()
            }
            .onChange(of: style) { _, _ in render() }
        }
    }

    @MainActor
    private func render() {
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, .dark))
        renderer.scale = 1
        rendered = renderer.uiImage
    }
}
