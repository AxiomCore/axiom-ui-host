# Axiom UI Host for iOS

This is Axiom's product host, not a fork or distribution of the Lynx Explorer
application. It owns one window, the Axiom runtime module, a verified bundle
provider, and a single `LynxView`. The renderer is embedded as an engine.

`AxiomBundleProvider` is the only authority that resolves bundles. Release mode
will accept only a verified bundle installed by the Axiom CLI; development mode
will later accept revisions through Axiom's local hot-reload transport. Neither
path writes generated renderer source into an application workspace.

The structure follows Lynx's documented existing-app integration: a native host
supplies a template provider, constructs a `LynxView`, and loads an Axiom-owned
bundle name. Explorer, its scanner, and its devtool dependencies are absent.
