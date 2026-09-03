/// Identifier to which a Web Proof-of-Origin token is cryptographically bound.
///
/// Bindings are protocol metadata owned by each InnerTube client profile. They
/// must not be inferred globally: for example, WEB_REMIX binds both player and
/// GVS tokens to visitorData while ordinary WEB/MWEB player tokens are
/// video-bound.
enum YoutubePoTokenBinding { visitorData, videoId }
