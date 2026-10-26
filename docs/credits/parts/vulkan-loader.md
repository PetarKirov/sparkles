### Vulkan loader

| Field          | Value                                           |
| -------------- | ----------------------------------------------- |
| Version source | nixpkgs `vulkan-loader`                         |
| Licence        | `Apache-2.0`                                    |
| Home           | https://github.com/KhronosGroup/Vulkan-Loader   |
| Ships as       | `-lvulkan` on the desktop terminal's native arm |

Finds the GPU's Vulkan driver and hands the terminal's native arm its device:
`sparkles:vulkan` and `sparkles:ui-vulkan` draw every frame through it, where
the raylib build draws with OpenGL.

::: details Licence text

```text
<!-- @include: ../licenses/vulkan-loader/LICENSE.txt -->
```

:::
