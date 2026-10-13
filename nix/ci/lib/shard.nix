# Static sharding: Longest-Processing-Time-first bin packing, as a pure
# function. Sorting heaviest-first and always filling the lightest bin is
# within 4/3 of optimal, which for a few dozen packages is plenty.
#
# Static on purpose: a shard is a fixed set of packages, so its job id and
# its YAML never change with what a pull request touched. Laziness then
# works *inside* a shard — the job tests only those of its packages whose
# closure is new, and is skipped when there are none.
{ lib }:
{
  # `lpt { shards; weight; } items` → a list of `shards` lists of items.
  lpt =
    { shards, weight }:
    items:
    let
      heaviestFirst = lib.sort (a: b: weight a > weight b || (weight a == weight b && a < b)) items;
      empty = lib.genList (_: {
        load = 0;
        members = [ ];
      }) shards;
      lightest =
        bins:
        lib.foldl' (
          best: i: if (builtins.elemAt bins i).load < (builtins.elemAt bins best).load then i else best
        ) 0 (lib.range 0 (shards - 1));
      place =
        bins: item:
        let
          i = lightest bins;
        in
        lib.imap0 (
          j: bin:
          if j == i then
            {
              load = bin.load + weight item;
              members = bin.members ++ [ item ];
            }
          else
            bin
        ) bins;
    in
    map (bin: lib.sort (a: b: a < b) bin.members) (lib.foldl' place empty heaviestFirst);
}
