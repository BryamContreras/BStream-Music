import SwiftUI
import WidgetKit

private let groupId = "group.com.bstream.bstreamMusic"
private let widgetKind = "BStreamNowPlaying"
private let glassWidgetKind = "BStreamNowPlayingGlass"
private let defaultArtworkBackdrop = Color(red: 0.07, green: 0.12, blue: 0.17)

struct NowPlayingEntry: TimelineEntry {
  let date: Date
  let title: String
  let artist: String
  let isPlaying: Bool
  let isLoading: Bool
  let loadingLabel: String
  let isFavorite: Bool
  let repeatMode: String
  let accent: Color
  let backdrop: Color?
  let cover: UIImage?
  let coverIdentity: String
}

struct NowPlayingProvider: TimelineProvider {
  let usesArtworkBackdrop: Bool

  func placeholder(in context: Context) -> NowPlayingEntry {
    NowPlayingEntry(date: Date(), title: "Sin reproducción", artist: "Toca para abrir",
                    isPlaying: false, isLoading: false, loadingLabel: "Cargando canción",
                    isFavorite: false, repeatMode: "off",
                    accent: .white,
                    backdrop: usesArtworkBackdrop ? defaultArtworkBackdrop : nil,
                    cover: nil, coverIdentity: "")
  }

  func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
    completion(readEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
    completion(Timeline(entries: [readEntry()], policy: .never))
  }

  private func readEntry() -> NowPlayingEntry {
    let defaults = UserDefaults(suiteName: groupId)
    let languageCode = defaults?.string(forKey: "language") ?? "es"
    let english = languageCode == "en"
    let savedLoadingLabel = defaults?.string(forKey: "loadingLabel")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let loadingLabel = savedLoadingLabel.isEmpty
      ? (english ? "Loading song" : "Cargando canción") : savedLoadingLabel
    let raw = UInt32(truncatingIfNeeded: defaults?.integer(forKey: "accent") ?? 0xFFF5F7F5)
    let accent = Color(
      red: Double((raw >> 16) & 0xFF) / 255,
      green: Double((raw >> 8) & 0xFF) / 255,
      blue: Double(raw & 0xFF) / 255
    )
    let cover: UIImage?
    if defaults?.bool(forKey: "hasCover") == true,
       let filename = defaults?.string(forKey: "coverFile"),
       let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) {
      cover = UIImage(contentsOfFile: container.appendingPathComponent(filename).path)
    } else {
      cover = nil
    }
    let title = defaults?.string(forKey: "title") ?? ""
    let hasTrack = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
      !(defaults?.string(forKey: "trackId") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return NowPlayingEntry(
      date: Date(), title: title.isEmpty ? (english ? "Not playing" : "Sin reproducción") : title,
      artist: title.isEmpty ? (english ? "Tap to open" : "Toca para abrir") : (defaults?.string(forKey: "artist") ?? ""),
      isPlaying: defaults?.bool(forKey: "playing") ?? false,
      isLoading: hasTrack && (defaults?.bool(forKey: "loading") ?? false),
      loadingLabel: loadingLabel,
      isFavorite: defaults?.bool(forKey: "favorite") ?? false,
      repeatMode: defaults?.string(forKey: "repeatMode") ?? "off",
      accent: accent,
      backdrop: usesArtworkBackdrop ? (artworkTone(cover) ?? defaultArtworkBackdrop) : nil,
      cover: cover,
      coverIdentity: defaults?.string(forKey: "coverFile") ?? ""
    )
  }
}

private func artworkTone(_ cover: UIImage?) -> Color? {
  guard let image = cover?.cgImage else { return nil }
  let side = 24
  var pixels = [UInt8](repeating: 0, count: side * side * 4)
  return pixels.withUnsafeMutableBytes { bytes -> Color? in
    guard let context = CGContext(
      data: bytes.baseAddress, width: side, height: side,
      bitsPerComponent: 8, bytesPerRow: side * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let data = bytes.bindMemory(to: UInt8.self)
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var count = 0.0
    for index in stride(from: 0, to: data.count, by: 4) where data[index + 3] > 128 {
      red += Double(data[index]) / 255
      green += Double(data[index + 1]) / 255
      blue += Double(data[index + 2]) / 255
      count += 1
    }
    guard count > 0 else { return nil }
    return Color(red: 0.04 + red / count * 0.38,
                 green: 0.05 + green / count * 0.35,
                 blue: 0.07 + blue / count * 0.34)
  }
}

private struct ArtworkView: View {
  let cover: UIImage?
  let keepsCoverColor: Bool

  @ViewBuilder var body: some View {
    Group {
      if let cover {
        let image = Image(uiImage: cover).resizable()
        if #available(iOS 18.0, *), keepsCoverColor {
          image.widgetAccentedRenderingMode(.fullColor).scaledToFill()
        } else {
          image.scaledToFill()
        }
      } else {
        ZStack {
          LinearGradient(colors: [Color(red: 0.17, green: 0.27, blue: 0.36),
                                  Color(red: 0.07, green: 0.10, blue: 0.17)],
                         startPoint: .topLeading, endPoint: .bottomTrailing)
          Image(systemName: "waveform").font(.system(size: 28, weight: .semibold))
            .foregroundColor(.white.opacity(0.8))
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct NowPlayingWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: NowPlayingEntry

  private func action(_ name: String) -> URL {
    URL(string: "bstreammusic://widget?action=\(name)")!
  }

  @ViewBuilder var body: some View {
    let content = Group {
      if family == .systemSmall {
        small
      } else if family == .systemLarge {
        large
      } else {
        medium
      }
    }
    if #available(iOS 17.0, *) {
      content.containerBackground(for: .widget) { background }
    } else {
      content.background(background)
    }
  }

  @ViewBuilder private var background: some View {
    if let backdrop = entry.backdrop {
      LinearGradient(colors: [backdrop, Color(red: 0.025, green: 0.035, blue: 0.06)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
        .id(entry.coverIdentity)
        .transition(.opacity.animation(.easeInOut(duration: 0.24)))
    } else {
      // WidgetKit can replace this container background with system glass.
      ContainerRelativeShape()
        .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.40, blue: 0.44).opacity(0.58),
                                      Color(red: 0.22, green: 0.27, blue: 0.32).opacity(0.60),
                                      Color(red: 0.15, green: 0.19, blue: 0.24).opacity(0.63)],
                             startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(
          ContainerRelativeShape().stroke(
            LinearGradient(colors: [Color(red: 0.67, green: 0.96, blue: 1).opacity(0.66),
                                    .white.opacity(0.20),
                                    Color(red: 0.99, green: 0.75, blue: 0.94).opacity(0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 2
          )
        )
    }
  }

  private var small: some View {
    VStack(alignment: .leading, spacing: 7) {
      artwork.frame(maxWidth: .infinity, maxHeight: .infinity)
      Text("\(entry.title) · \(entry.artist)")
        .font(.system(size: 13, weight: .bold)).lineLimit(1)
        .foregroundColor(.white)
    }
    .padding(12)
    .widgetURL(action("open"))
  }

  private var medium: some View {
    HStack(spacing: 12) {
      artwork.frame(width: 70, height: 70)
      VStack(alignment: .leading, spacing: 9) {
        Text("\(entry.title) · \(entry.artist)")
          .font(.system(size: 14, weight: .bold)).lineLimit(1)
          .foregroundColor(.white)
        HStack(spacing: 4) {
          Spacer(minLength: 0)
          control("backward.end.fill", action: "previous", width: 34, height: 36)
          control(
            entry.repeatMode == "one" ? "repeat.1" : "repeat",
            action: "repeat",
            tint: entry.repeatMode == "off" ? .white : entry.accent,
            width: 34,
            height: 36
          )
          control(
            entry.isPlaying ? "pause.fill" : "play.fill",
            action: "toggle",
            width: 38,
            height: 38
          )
          control("forward.end.fill", action: "next", width: 34, height: 36)
          control(
            entry.isFavorite ? "heart.fill" : "heart",
            action: "favorite",
            tint: entry.isFavorite ? entry.accent : .white,
            width: 34,
            height: 36
          )
          Spacer(minLength: 0)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 2)
  }

  private var large: some View {
    VStack(spacing: 12) {
      Spacer(minLength: 0)
      HStack(spacing: 12) {
        artwork.frame(width: 92, height: 92)
        VStack(alignment: .leading, spacing: 4) {
          Text("BStream Music")
            .font(.system(size: 13)).lineLimit(1)
            .foregroundColor(.white.opacity(0.7))
          Text(entry.title)
            .font(.system(size: 18, weight: .bold)).lineLimit(1)
            .foregroundColor(.white)
          Text(entry.artist)
            .font(.system(size: 14)).lineLimit(1)
            .foregroundColor(.white.opacity(0.84))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 6) {
        Spacer(minLength: 0)
        control(
          entry.repeatMode == "one" ? "repeat.1" : "repeat",
          action: "repeat",
          tint: entry.repeatMode == "off" ? .white : entry.accent,
          width: 40,
          height: 44
        )
        control("backward.end.fill", action: "previous", width: 40, height: 44)
        control(
          entry.isPlaying ? "pause.fill" : "play.fill",
          action: "toggle", width: 48, height: 50
        )
        control("forward.end.fill", action: "next", width: 40, height: 44)
        control(
          entry.isFavorite ? "heart.fill" : "heart",
          action: "favorite",
          tint: entry.isFavorite ? entry.accent : .white,
          width: 40,
          height: 44
        )
        Spacer(minLength: 0)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .padding(.top, 18)
    .padding(.bottom, 2)
  }

  private var artwork: some View {
    ArtworkView(cover: entry.cover, keepsCoverColor: entry.backdrop == nil)
      .id(entry.coverIdentity)
      .transition(.opacity.animation(.easeInOut(duration: 0.24)))
  }

  private func control(
    _ symbol: String,
    action name: String,
    tint: Color = .white,
    width: CGFloat = 44,
    height: CGFloat = 44
  ) -> some View {
    Link(destination: action(name)) {
      ZStack {
        if name == "toggle" && entry.isLoading {
          // WidgetKit owns rendering and transition timing. Repeated reloads
          // must not be used to emulate an indefinitely spinning animation.
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: tint))
            .frame(width: height >= 50 ? 26 : 22, height: height >= 50 ? 26 : 22)
            .accessibilityLabel(Text(entry.loadingLabel))
            .transition(.opacity.animation(.easeInOut(duration: 0.18)))
        } else {
          Image(systemName: symbol)
            .font(.system(
              size: name == "repeat" || name == "favorite" ? 20 : (height >= 50 ? 27 : 23),
              weight: .bold
            ))
            .transition(.opacity.animation(.easeInOut(duration: 0.18)))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundColor(tint)
      .background(Circle().fill(Color.clear))
    }
    .frame(width: width, height: height)
  }
}

@main
struct BStreamNowPlayingWidgets: WidgetBundle {
  var body: some Widget {
    BStreamNowPlayingWidget()
    BStreamNowPlayingWidget(usesArtworkBackdrop: false)
  }
}

struct BStreamNowPlayingWidget: Widget {
  let usesArtworkBackdrop: Bool

  init() {
    self.init(usesArtworkBackdrop: true)
  }

  init(usesArtworkBackdrop: Bool) {
    self.usesArtworkBackdrop = usesArtworkBackdrop
  }

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: usesArtworkBackdrop ? widgetKind : glassWidgetKind,
      provider: NowPlayingProvider(usesArtworkBackdrop: usesArtworkBackdrop)
    ) { entry in
      NowPlayingWidgetView(entry: entry)
    }
    .configurationDisplayName(usesArtworkBackdrop ? "BStream Music" : "BStream Music · Liquid Glass")
    .description("Tu canción actual con portada y controles.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
