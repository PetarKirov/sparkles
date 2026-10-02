### curl

| Field          | Value                            |
| -------------- | -------------------------------- |
| Version source | nixpkgs `curl`                   |
| Licence        | `curl`                           |
| Home           | https://curl.se                  |
| Ships as       | `-lcurl` in hue's desktop builds |

libcurl carries hue's forge client: fetching a pull request's diff, files and
review threads for the diff viewer, through Phobos' `std.net.curl`. The
Android build links no curl.

::: details Licence text

```text
<!-- @include: ../licenses/curl/COPYING -->
```

:::
