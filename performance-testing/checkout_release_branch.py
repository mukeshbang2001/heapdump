#!/usr/bin/env python3

import sys
from subprocess import check_output, check_call
from pathlib import Path
import xml.etree.cElementTree as ET

command_to_invoke = sys.argv[1:]
if not command_to_invoke:
    raise ValueError("No command to invoke on release branch")

check_call(['git', 'fetch', 'origin'])

here = Path(__file__).parent.parent.parent.resolve()

# parse and extract the version element from the pom.xml at the root of the repository
# using xpath over an ElementTree built by a TreeBuilder
tree = ET.parse((here / "pom.xml").open(), parser=ET.XMLParser(target=ET.TreeBuilder()))
version = tree.find('./{http://maven.apache.org/POM/4.0.0}version').text

major, minor, patch = map(int, version.split('-')[0].split('.'))

# assumption here is that the SNAPSHOT will always be the latest release with a patch of +1
# this will likely break if the current patch version is 0, but we hope to migrate to something more
# sturdy before that happens
patch -= 1

branch = f'release/{major}.{minor}.{patch}'

current_branch = check_output(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], text=True).strip()

check_call(["git", "switch", branch])

try:
    check_call(command_to_invoke)
finally:
    check_call(["git", "switch", current_branch])
