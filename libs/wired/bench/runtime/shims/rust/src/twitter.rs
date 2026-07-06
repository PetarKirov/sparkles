//! The partial Twitter mirror for the typed `decode` op (canonical
//! definition: the D-side twitter.d). serde ignores unknown fields by
//! default, matching the cross-engine contract; all checksum sums use
//! wrapping 64-bit addition (id sums overflow u64 by design).

use serde::Deserialize;

#[derive(Deserialize)]
pub struct TwitterUser {
    pub id: i64,
    pub screen_name: String,
    pub followers_count: i64,
}

#[derive(Deserialize)]
pub struct TwitterStatus {
    pub created_at: String,
    pub id: i64,
    pub text: String,
    pub user: TwitterUser,
    pub retweet_count: i64,
    pub favorite_count: i64,
}

#[derive(Deserialize)]
pub struct Twitter {
    pub statuses: Vec<TwitterStatus>,
}

/// Mirrors `jb_twitter_stats` in the shim header.
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct JbTwitterStats {
    pub status_count: u64,
    pub id_sum: u64,
    pub user_id_sum: u64,
    pub followers_sum: u64,
    pub retweet_sum: u64,
    pub favorite_sum: u64,
    pub text_bytes: u64,
    pub screen_name_bytes: u64,
    pub created_at_bytes: u64,
}

/// The checksum of a decoded document.
pub fn stats_of(t: &Twitter) -> JbTwitterStats {
    let mut s = JbTwitterStats {
        status_count: t.statuses.len() as u64,
        ..Default::default()
    };
    for st in &t.statuses {
        s.id_sum = s.id_sum.wrapping_add(st.id as u64);
        s.user_id_sum = s.user_id_sum.wrapping_add(st.user.id as u64);
        s.followers_sum = s.followers_sum.wrapping_add(st.user.followers_count as u64);
        s.retweet_sum = s.retweet_sum.wrapping_add(st.retweet_count as u64);
        s.favorite_sum = s.favorite_sum.wrapping_add(st.favorite_count as u64);
        s.text_bytes += st.text.len() as u64;
        s.screen_name_bytes += st.user.screen_name.len() as u64;
        s.created_at_bytes += st.created_at.len() as u64;
    }
    s
}
