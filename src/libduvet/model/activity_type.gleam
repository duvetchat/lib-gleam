/// The values an activity's `type` takes.
///
/// A game or another app: the gateway leaves the type out.
pub const playing = 0

/// Music. Spotify's, as the desktop app shares it, has the song in the
/// activity's `details`, the artist in its `state`, the album in its assets'
/// `large_text`, and the song's start and end.
pub const listening = 2
