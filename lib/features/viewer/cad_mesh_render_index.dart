import 'dart:typed_data';

/// Small immutable source-order bounds index, not a simplified mesh. Built
/// during packet decoding off the UI isolate; original buffers stay intact.
class CadMeshRenderIndex {
  CadMeshRenderIndex._(this.bounds, this.indexCount);

  static const trianglesPerChunk = 512;
  static const indicesPerChunk = trianglesPerChunk * 3;
  final Float64List bounds; // min XYZ, max XYZ for each source chunk
  final int indexCount;
  int get chunkCount => bounds.length ~/ 6;

  static CadMeshRenderIndex build(Float64List xyz, Uint32List indices) {
    if (xyz.length % 3 != 0 ||
        indices.length % 3 != 0 ||
        xyz.any((v) => !v.isFinite)) {
      throw const FormatException('Invalid CAD mesh packet geometry');
    }
    final chunks = (indices.length + indicesPerChunk - 1) ~/ indicesPerChunk;
    final bounds = Float64List(chunks * 6);
    final vertexCount = xyz.length ~/ 3;
    for (var chunk = 0; chunk < chunks; chunk++) {
      var minX = double.infinity,
          minY = double.infinity,
          minZ = double.infinity;
      var maxX = double.negativeInfinity,
          maxY = double.negativeInfinity,
          maxZ = double.negativeInfinity;
      final start = chunk * indicesPerChunk;
      final end = start + indicesPerChunk < indices.length
          ? start + indicesPerChunk
          : indices.length;
      for (var i = start; i < end; i++) {
        final vertex = indices[i];
        if (vertex >= vertexCount) {
          throw const FormatException('Invalid CAD mesh packet geometry');
        }
        final at = vertex * 3;
        final x = xyz[at], y = xyz[at + 1], z = xyz[at + 2];
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (z < minZ) minZ = z;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
        if (z > maxZ) maxZ = z;
      }
      final at = chunk * 6;
      bounds[at] = minX;
      bounds[at + 1] = minY;
      bounds[at + 2] = minZ;
      bounds[at + 3] = maxX;
      bounds[at + 4] = maxY;
      bounds[at + 5] = maxZ;
    }
    return CadMeshRenderIndex._(bounds.asUnmodifiableView(), indices.length);
  }

  /// Interval projection uses the same subtract/multiply/add order as vertex
  /// projection. Each endpoint is chosen by coefficient sign, not by the
  /// declared scene bounds. Roundoff and float32 conversion get an additional
  /// conservative margin; overflow fails open (renders the chunk).
  bool isOutside(
    int chunk, {
    required double centerX,
    required double centerY,
    required double centerZ,
    required double rightX,
    required double rightY,
    required double rightZ,
    required double upX,
    required double upY,
    required double upZ,
    required double screenX,
    required double screenY,
    required double scale,
    required double width,
    required double height,
  }) {
    if (!scale.isFinite || scale <= 0) return false;
    final at = chunk * 6;
    final x0 = bounds[at] - centerX,
        y0 = bounds[at + 1] - centerY,
        z0 = bounds[at + 2] - centerZ;
    final x1 = bounds[at + 3] - centerX,
        y1 = bounds[at + 4] - centerY,
        z1 = bounds[at + 5] - centerZ;
    final minRight =
        (rightX >= 0 ? x0 : x1) * rightX +
        (rightY >= 0 ? y0 : y1) * rightY +
        (rightZ >= 0 ? z0 : z1) * rightZ;
    final maxRight =
        (rightX >= 0 ? x1 : x0) * rightX +
        (rightY >= 0 ? y1 : y0) * rightY +
        (rightZ >= 0 ? z1 : z0) * rightZ;
    final minUp =
        (upX >= 0 ? x0 : x1) * upX +
        (upY >= 0 ? y0 : y1) * upY +
        (upZ >= 0 ? z0 : z1) * upZ;
    final maxUp =
        (upX >= 0 ? x1 : x0) * upX +
        (upY >= 0 ? y1 : y0) * upY +
        (upZ >= 0 ? z1 : z0) * upZ;
    final minX = screenX + minRight * scale, maxX = screenX + maxRight * scale;
    final minY = screenY - maxUp * scale, maxY = screenY - minUp * scale;
    if (!minX.isFinite || !maxX.isFinite || !minY.isFinite || !maxY.isFinite) {
      return false;
    }
    // >= float32 relative error, also generous for f64 dot-product rounding.
    final magnitude = minX.abs() + maxX.abs() + minY.abs() + maxY.abs();
    if (magnitude > 3e38) return false; // float32 overflow also fails open
    final margin = 4 + magnitude * 1e-6;
    return maxX < -margin ||
        minX > width + margin ||
        maxY < -margin ||
        minY > height + margin;
  }
}
