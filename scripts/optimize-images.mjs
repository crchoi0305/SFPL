// Build-time image optimizer for the SFPL site.
//
// Runs on every Netlify deploy (see netlify.toml). It walks the image
// folders and, for any file that is oversized in pixels or unusually
// heavy in bytes, resizes it to fit within MAX_DIM and re-encodes it.
// EXIF orientation is baked in and metadata stripped.
//
// Idempotent by design: a file that is already <= MAX_DIM on its long
// edge AND under HEAVY_BYTES is left untouched, so repeated builds do not
// recompress the same image (which would slowly degrade quality).
//
// Image failures never fail the build - they are logged and skipped.

import { readdir, readFile, writeFile, rename, stat } from "node:fs/promises";
import { join } from "node:path";

let sharp;
try {
  sharp = (await import("sharp")).default;
} catch (err) {
  console.warn("[optimize-images] sharp not available, skipping optimization:", err.message);
  process.exit(0);
}

const ROOTS = ["content/assets", "assets"];
const MAX_DIM = 1920;        // longest edge, px
const JPEG_QUALITY = 82;
const HEAVY_BYTES = 1_400_000; // recompress in-bounds files heavier than this once
const IMG_RE = /\.(jpe?g|png)$/i;

sharp.cache(false);
sharp.concurrency(2);

async function* walk(dir) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return; // folder doesn't exist in this checkout
  }
  for (const entry of entries) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) {
      yield* walk(p);
    } else if (entry.isFile()) {
      yield p;
    }
  }
}

let scanned = 0, optimized = 0, skipped = 0, errors = 0, savedBytes = 0;

for (const root of ROOTS) {
  for await (const file of walk(root)) {
    if (!IMG_RE.test(file)) continue;
    scanned++;

    try {
      const buf = await readFile(file);
      const isPng = /\.png$/i.test(file);

      const meta = await sharp(buf, { failOn: "none" }).metadata();
      const w = meta.width || 0;
      const h = meta.height || 0;
      const longEdge = Math.max(w, h);

      const oversized = longEdge > MAX_DIM;
      const heavy = buf.length > HEAVY_BYTES;

      if (!oversized && !heavy) {
        skipped++;
        continue;
      }

      let pipeline = sharp(buf, { failOn: "none" }).rotate(); // apply EXIF orientation, strip metadata
      if (oversized) {
        pipeline = pipeline.resize(MAX_DIM, MAX_DIM, {
          fit: "inside",
          withoutEnlargement: true,
        });
      }

      const out = isPng
        ? await pipeline.png({ compressionLevel: 9, effort: 8 }).toBuffer()
        : await pipeline.jpeg({ quality: JPEG_QUALITY, mozjpeg: true }).toBuffer();

      // Only replace when we actually made it smaller (or a rotation was needed).
      if (out.length < buf.length || meta.orientation > 1) {
        const tmp = `${file}.opt-tmp`;
        await writeFile(tmp, out);
        await rename(tmp, file);
        savedBytes += Math.max(0, buf.length - out.length);
        optimized++;
        console.log(
          `  ${file}  ${(buf.length / 1024).toFixed(0)}KB -> ${(out.length / 1024).toFixed(0)}KB` +
          (oversized ? `  (${w}x${h} -> fit ${MAX_DIM})` : "")
        );
      } else {
        skipped++;
      }
    } catch (err) {
      errors++;
      console.warn(`  ! ${file}: ${err.message}`);
    }
  }
}

console.log(
  `\n[optimize-images] scanned ${scanned}, optimized ${optimized}, skipped ${skipped}, errors ${errors}` +
  `  |  saved ${(savedBytes / 1024 / 1024).toFixed(1)} MB`
);

process.exit(0); // never fail the deploy over image processing
