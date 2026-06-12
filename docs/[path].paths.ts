import fs from 'fs';
import path from 'path';

export default {
  paths() {
    const repoDir = process.cwd();
    const docsDir = path.resolve(repoDir, 'docs');
    const routes: any[] = [];

    function isBinaryFile(filename: string) {
      const binaryExtensions = [
        '.exe',
        '.dll',
        '.so',
        '.a',
        '.o',
        '.obj',
        '.dylib',
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.ico',
        '.webp',
        '.pdf',
        '.zip',
        '.tar.gz',
        '.tgz',
      ];
      const ext = path.extname(filename).toLowerCase();
      return binaryExtensions.includes(ext);
    }

    function getLanguage(name: string) {
      const ext = path.extname(name).toLowerCase();
      if (ext === '.d') return 'd';
      if (ext === '.c') return 'c';
      if (ext === '.h') return 'c';
      if (ext === '.json') return 'json';
      if (ext === '.sh') return 'bash';
      if (ext === '.sdl') return 'd';
      if (ext === '.toml') return 'toml';
      if (ext === '.yaml' || ext === '.yml') return 'yaml';
      if (ext === '.go') return 'go';
      if (ext === '.py') return 'python';
      if (ext === '.ts') return 'typescript';
      if (ext === '.js') return 'javascript';
      if (ext === '.css') return 'css';
      if (name === 'Cargo.toml') return 'toml';
      if (name === 'MODULE.bazel' || name === 'BUILD.bazel') return 'python';
      if (name === 'Makefile') return 'makefile';
      if (name === 'go.work') return 'go';
      return '';
    }

    // Scan docs directory
    function scanDocs(dir: string) {
      if (!fs.existsSync(dir)) return;
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        const relPath = path.relative(docsDir, fullPath).replace(/\\/g, '/');

        if (entry.isDirectory()) {
          if (
            entry.name === '.vitepress' ||
            entry.name === 'node_modules' ||
            entry.name.startsWith('.')
          ) {
            continue;
          }

          const segments = relPath.split('/');
          const isInsideArtifactDir = segments.some(
            s => s === 'sample' || s === 'example' || s === 'examples',
          );

          if (isInsideArtifactDir) {
            if (
              entry.name === 'build' ||
              entry.name === 'bin' ||
              entry.name === 'obj' ||
              entry.name === '.dub'
            ) {
              continue;
            }

            // Recurse first
            scanDocs(fullPath);

            // Generate directory listing
            const children = fs.readdirSync(fullPath, { withFileTypes: true });
            const folderLinks: string[] = [];
            const fileLinks: string[] = [];

            for (const child of children) {
              if (child.name.startsWith('.') || child.name === 'index.md') {
                continue;
              }
              if (child.isDirectory()) {
                if (
                  child.name === 'build' ||
                  child.name === 'bin' ||
                  child.name === 'obj' ||
                  child.name === '.dub'
                ) {
                  continue;
                }
                folderLinks.push(
                  `- [${child.name}/](./${child.name}/index.md)`,
                );
              } else {
                if (isBinaryFile(child.name) || child.name.endsWith('.md')) {
                  continue;
                }
                fileLinks.push(`- [${child.name}](./${child.name}.md)`);
              }
            }

            const content = [
              `# Directory: ${entry.name}`,
              '',
              `[Back to parent](../)`,
              '',
              folderLinks.length > 0
                ? '## Folders\n' + folderLinks.join('\n') + '\n'
                : '',
              fileLinks.length > 0
                ? '## Files\n' + fileLinks.join('\n') + '\n'
                : '',
            ]
              .filter(x => x !== '')
              .join('\n');

            routes.push({
              params: { path: `${relPath}/index` },
              content,
              frontmatter: { layout: 'page', aside: false },
            });
          } else {
            scanDocs(fullPath);
          }
        } else {
          // File in docs
          const name = entry.name;
          if (
            name.startsWith('.') ||
            name.endsWith('.md') ||
            isBinaryFile(name)
          ) {
            continue;
          }

          const segments = relPath.split('/');
          const isInsideArtifactDir = segments.some(
            s => s === 'sample' || s === 'example' || s === 'examples',
          );
          const isDOrC = name.endsWith('.d') || name.endsWith('.c');

          if (isInsideArtifactDir || isDOrC) {
            let lang = getLanguage(name);
            const hasParentIndex = isInsideArtifactDir;

            const content = [
              `# ${name}`,
              '',
              hasParentIndex ? `[Back to parent](./)` : `[Back to home](/)`,
              '',
              `<<< @/${relPath}${lang ? '{' + lang + '}' : ''}`,
            ].join('\n');

            routes.push({
              params: { path: relPath },
              content,
              frontmatter: { layout: 'page', aside: false },
            });
          }
        }
      }
    }

    // Scan external directories (libs and apps) for .d and .c files
    function scanExternal(dir: string) {
      if (!fs.existsSync(dir)) return;
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        const relPath = path.relative(repoDir, fullPath).replace(/\\/g, '/');

        if (entry.isDirectory()) {
          if (
            entry.name === 'node_modules' ||
            entry.name.startsWith('.') ||
            entry.name === 'build' ||
            entry.name === 'bin' ||
            entry.name === 'obj' ||
            entry.name === '.dub'
          ) {
            continue;
          }
          scanExternal(fullPath);
        } else {
          const name = entry.name;
          if (name.endsWith('.d') || name.endsWith('.c')) {
            let lang = getLanguage(name);
            const content = [
              `# ${name}`,
              '',
              `[Back to home](/)`,
              '',
              `<<< @/../${relPath}${lang ? '{' + lang + '}' : ''}`,
            ].join('\n');

            routes.push({
              params: { path: relPath },
              content,
              frontmatter: { layout: 'page', aside: false },
            });
          }
        }
      }
    }

    scanDocs(docsDir);
    scanExternal(path.join(repoDir, 'libs'));
    scanExternal(path.join(repoDir, 'apps'));

    return routes;
  },
};
