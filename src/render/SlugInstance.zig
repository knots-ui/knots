//! One glyph quad. Bounds and band data come from the glyph store's slot table.

origin: [2]f32,
/// Logical pixels per em.
size: f32,
slot: u32,
col: [4]f16,
clip_node: f32 = 0,
