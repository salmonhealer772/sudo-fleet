# Saved agent identities live here

This directory is empty by default. A saved identity package (a *glimor*) is one
agent's memory, persona and settings, and belongs to the instance that created
it, not to this repository.

bin/k8s-up.sh deploys a clean agent when no package is present for a name, and
resumes one when it is. Put a package at deployments/<Name>/ to seed a deploy,
and keep it out of version control unless you have decided deliberately to
publish it.

See ../docs/COMPONENTS.md and ../docs/REPOSITORY-VS-INSTANCE.md.
