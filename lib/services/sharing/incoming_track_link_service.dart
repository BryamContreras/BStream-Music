import 'package:app_links/app_links.dart';

abstract interface class IncomingTrackLinkService {
  Stream<Uri> get links;
}

/// Receives both the initial URI and later activations from the platform.
///
/// Consumers must subscribe early and must not separately request an initial
/// link, otherwise some platforms can deliver the cold-start URI twice.
class AppLinksIncomingTrackLinkService implements IncomingTrackLinkService {
  AppLinksIncomingTrackLinkService({AppLinks? appLinks})
    : _links = (appLinks ?? AppLinks()).uriLinkStream;

  final Stream<Uri> _links;

  @override
  Stream<Uri> get links => _links;
}
