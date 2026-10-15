import SwiftUI
import WidgetKit

private let groupId = "group.com.bstream.bstreamMusic"
private let widgetKind = "BStreamNowPlaying"

struct NowPlayingEntry: TimelineEntry {
  let date: Date
  let title: String
  let artist: String
  let isPlaying: Bool
  let isFavorite: Bool
  let repeatMode: String
  let accent: Color
  let backdrop: Color
  let cover: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
  func placeholder(in context: Context) -> NowPlayingEntry {
    NowPlayingEntry(date: Date(), title: "Sin reproducción", artist: "Toca para abrir",
                    isPlaying: false, isFavorite: false, repeatMode: "off",
                    accent: .white,
                    backdrop: Color(red: 0.07, green: 0.12, blue: 0.17), cover: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
    completion(readEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
    completion(Timeline(entries: [readEntry()], policy: .never))
  }

  private func readEntry() -> NowPlayingEntry {
    let defaults = UserDefaults(suiteName: groupId)
    let english = defaults?.string(forKey: "language") == "en"
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
    return NowPlayingEntry(
      date: Date(), title: title.isEmpty ? (english ? "Not playing" : "Sin reproducción") : title,
      artist: title.isEmpty ? (english ? "Tap to open" : "Toca para abrir") : (defaults?.string(forKey: "artist") ?? ""),
      isPlaying: defaults?.bool(forKey: "playing") ?? false,
      isFavorite: defaults?.bool(forKey: "favorite") ?? false,
      repeatMode: defaults?.string(forKey: "repeatMode") ?? "off",
      accent: accent,
      backdrop: artworkTone(cover) ?? Color(red: 0.07, green: 0.12, blue: 0.17),
      cover: cover
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

  @ViewBuilder var body: some View {
    Group {
      if let cover {
        Image(uiImage: cover).resizable().scaledToFill()
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

  private var background: some View {
    LinearGradient(colors: [entry.backdrop,
                            Color(red: 0.025, green: 0.035, blue: 0.06)],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private var small: some View {
    VStack(alignment: .leading, spacing: 7) {
      ArtworkView(cover: entry.cover).frame(maxWidth: .infinity, maxHeight: .infinity)
      Text("\(entry.title) · \(entry.artist)")
        .font(.system(size: 13, weight: .bold)).lineLimit(1)
        .foregroundColor(.white)
    }
    .padding(12)
    .widgetURL(action("open"))
  }

  private var medium: some View {
    HStack(spacing: 12) {
      ArtworkView(cover: entry.cover).frame(width: 70, height: 70)
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
        ArtworkView(cover: entry.cover).frame(width: 92, height: 92)
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

  private func control(
    _ symbol: String,
    action name: String,
    tint: Color = .white,
    width: CGFloat = 44,
    height: CGFloat = 44
  ) -> some View {
    Link(destination: action(name)) {
      Image(systemName: symbol)
        .font(.system(size: height >= 50 ? 27 : 23, weight: .bold))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(tint)
        .background(
          Circle().fill(Color.clear)
        )
    }
    .frame(width: width, height: height)
  }
}

@main
struct BStreamNowPlayingWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: widgetKind, provider: NowPlayingProvider()) { entry in
      NowPlayingWidgetView(entry: entry)
    }
    .configurationDisplayName("BStream Music")
    .description("Tu canción actual con portada y controles.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
