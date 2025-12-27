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


def find_nidm_ttl_files(directory):
    """
    Find all NIDM TTL files in the directory structure.
    Searches for patterns like:
    - */nidm.ttl
    - */nidm_output/nidm.ttl
    - nidm/*/nidm.ttl
    - nidm/sub-*.ttl (FreeSurfer BIDS app output)
    - any other nidm.ttl in subdirectories
    """
    directory = Path(directory).resolve()
    nidm_files = []

    # Search for all nidm.ttl files recursively
    for ttl_file in directory.rglob("nidm.ttl"):
        nidm_files.append(ttl_file)

    # Also search for FreeSurfer pattern: nidm/sub-*.ttl
    for ttl_file in directory.rglob("nidm/sub-*.ttl"):
        nidm_files.append(ttl_file)

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
