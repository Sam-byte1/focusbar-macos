// WCAG relative-luminance contrast check for the rendered single-meter preview.
function luminance(hex) {
  const rgb = hex.match(/[a-f\d]{2}/gi).map(v => parseInt(v, 16) / 255)
    .map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}
function contrast(a, b) {
  const x = luminance(a), y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
const pairs = [['light fill/track', '#252525', '#d7d7d7'], ['dark fill/track', '#dedede', '#404040'], ['light text/surface', '#252525', '#ffffff'], ['dark text/surface', '#dedede', '#282828']];
for (const [name, a, b] of pairs) {
  const ratio = contrast(a, b);
  console.log(`${name}: ${ratio.toFixed(2)}:1 ${ratio >= 4.5 ? 'PASS' : 'FAIL'}`);
  if (ratio < 4.5) process.exitCode = 1;
}
