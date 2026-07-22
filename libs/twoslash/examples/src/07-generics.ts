// A tuple type flows through a destructuring query.
type Either2dOr3d = [number, number, number?]

function setCoordinate(coord: Either2dOr3d) {
  const [x, y, z] = coord
  //           ^?
}
