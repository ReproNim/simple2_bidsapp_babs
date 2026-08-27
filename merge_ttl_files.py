#!/usr/bin/env python3
"""
Merge NIDM TTL files from study output directory.
Searches for all nidm.ttl files in the output directory structure and merges them.
"""

import argparse
import sys
from pathlib import Path
from rdflib import Graph, Namespace


def remove_duplication(g):
    """Remove duplicate qualified associations from the RDF graph."""
    prov = Namespace("http://www.w3.org/ns/prov#")

    seen = {}  # key: (acq, agent, role) -> chosen assoc node
    to_remove = []  # (acq, assoc) links to remove
    assoc_nodes_to_delete = set()

    for acq, assoc in g.subject_objects(prov.qualifiedAssociation):
        # only consider associations that look like the simple pattern
        agent = g.value(assoc, prov.agent)
        role = g.value(assoc, prov.hadRole)
        if agent is None or role is None:
            continue  # skip unusual cases

        key = (acq, agent, role)
        if key not in seen:
            seen[key] = assoc
        else:
            # duplicate association: drop the link and the assoc node triples
            to_remove.append((acq, assoc))
            assoc_nodes_to_delete.add(assoc)

    # unlink duplicates and remove the blank nodes
    for acq, assoc in to_remove:
        g.remove((acq, prov.qualifiedAssociation, assoc))
        # remove all outgoing edges from assoc
        g.remove((assoc, None, None))

    return g


# Subtrees that contain nidm.ttl files which are NOT this run's results.
#
# Run this manually against a BABS project that has already been harvested by
# the dataset's own post_babs.sh (site-<SITE>/code/post_babs.sh) -- that script
# unzips in place and deliberately does not merge TTLs. The exclusions below are
# what make merging safe on such a project, because the project root holds both
# the unzipped results AND:
#   sourcedata/NIDM/sub-*/nidm.ttl  -- the INPUT NIDM the app appended to
#   merge_ds/                       -- babs merge's clone of the same results
#   .babs/, containers/, code/      -- machinery, and the RIA object store
# Merging the inputs back in would silently double every input graph.
EXCLUDED_DIRS = {
    "sourcedata",
    "merge_ds",
    ".babs",
    ".git",
    ".datalad",
    "containers",
    "code",
    "inputs",
}


def find_nidm_ttl_files(directory):
    """
    Find this run's NIDM TTL files under `directory`.

    Matches:
    - sub-<id>[/ses-<x>]/nidm.ttl   (per-subject layout -- current)
    - any other nidm.ttl in subdirectories
    - nidm/sub-*.ttl                (legacy FreeSurfer BIDS app output)

    Skips EXCLUDED_DIRS so input NIDM and merge_ds copies are never merged.
    """
    directory = Path(directory).resolve()

    def is_result(path):
        rel = path.relative_to(directory)
        return not any(part in EXCLUDED_DIRS for part in rel.parts)

    nidm_files = [f for f in directory.rglob("nidm.ttl") if is_result(f)]
    # Legacy FreeSurfer pattern: nidm/sub-*.ttl
    nidm_files += [f for f in directory.rglob("nidm/sub-*.ttl") if is_result(f)]

    # Deduplicate and sort
    return sorted(set(nidm_files))


def main():
    parser = argparse.ArgumentParser(
        description="Merge NIDM TTL files from a study output directory"
    )
    parser.add_argument(
        "directory",
        type=Path,
        help="Path to the output directory containing nidm.ttl files"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output file for merged TTL (default: <directory>/nidm_merge.ttl)"
    )
    
    args = parser.parse_args()

    output_dir = args.directory.resolve()
    if not output_dir.exists():
        parser.error(f"{output_dir} does not exist")

    # Find all nidm.ttl files
    nidm_files = find_nidm_ttl_files(output_dir)
    
    if not nidm_files:
        print(f"WARNING: No NIDM TTL files found in {output_dir}", file=sys.stderr)
        return 0

    print(f"Found {len(nidm_files)} NIDM TTL file(s):")
    for f in nidm_files:
        print(f"  - {f}")

    # Create merged graph
    g = Graph()
    
    for nidm_f in nidm_files:
        print(f"Parsing {nidm_f}...")
        try:
            g.parse(nidm_f, format="turtle")
        except Exception as e:
            print(f"WARNING: Failed to parse {nidm_f}: {e}", file=sys.stderr)
            continue

    print(f"Total triples before deduplication: {len(g)}")
    
    # Remove duplicates
    g = remove_duplication(g)
    
    print(f"Total triples after deduplication: {len(g)}")
    
    # Determine output file
    if args.output is None:
        output_file = output_dir / "nidm_merge.ttl"
    else:
        output_file = args.output.resolve()
    
    # Write merged TTL
    print(f"Writing merged TTL to {output_file}...")
    g.serialize(destination=output_file, format="turtle")
    
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
