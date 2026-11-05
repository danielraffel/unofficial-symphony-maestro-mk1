# Landing page

This preserves the supplied landing-page design and uses an explicit gallery of
all fourteen repository screenshots. The 8MicPre image is explicitly labeled
as a simulated card; the other captures are presented without simulator labels.
Update dialogs document Sparkle. Screenshot approval is separate from gallery
implementation.

From the repository root:

```sh
python3 Tools/build-website.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory website/dist
```

Open http://127.0.0.1:8765/. All page assets use relative URLs, so the assembled
folder can later be published at the project Pages path
`/unofficial-symphony-maestro-mk1/`. The generated `website/dist` is ignored.
No workflow here automatically deploys the site or changes the production feed.
Publishing and the existing generouscorp.com Pages/domain configuration require
separate review. Do not add a project CNAME just to obtain a project subpath.

Capture replacement app screenshots using macOS window capture (Command-Shift-4,
then Space), retaining the PNG alpha channel and native shadow. Use the simulator
in a separate capture app/preferences domain. Check each image for sharing
indicators, menus, cursor artifacts and personal information before replacing the
source PNG. Do not flatten transparent corners onto white.
