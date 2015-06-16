# README #

### What is this repository for? ###

Contains all of the logic required to setup an Scalable, Automatically Deployed SQUID Proxy in AWS.

### How do I get set up? ###

* Build script (/scripts/build) will build (and optionally deploy) the package containing Squid.
* Environment that uses the package can be created via scripts in /scripts/environment/.

### Contribution guidelines ###

* Functionality should have a test. Being that this is mostly Powershell, write Pester tests.

### Who do I talk to? ###

Todd Bowles initially wrote this, but the Console/Gateway team is good as well.