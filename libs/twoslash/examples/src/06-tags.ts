// @annotate: compacts falsy values out of an array
function compact(arr: (string | null)[]) {
  return arr.filter(Boolean)
}

const kept = compact(["a", null, "b"])
