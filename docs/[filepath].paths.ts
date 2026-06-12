import fs from 'fs';
import path from 'path';

export default {
  paths() {
    const repoDir = process.cwd();
    const docsDir = path.resolve(repoDir, 'docs');
    console.log('=== PATHS LOADER === ');
    console.log('process.cwd():', repoDir);
    console.log('docsDir:', docsDir);
    console.log('docsDir exists:', fs.existsSync(docsDir));
    const routes: any[] = [];

    const targetFiles = new Set<string>(); // Relative to repoDir
    const targetDirs = new Set<string>(); // Relative to repoDir

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

    function shouldProcessFile(filename: string, absPath: string): boolean {
      if (filename.startsWith('.') || filename.endsWith('.md')) {
        return false;
      }
      if (isBinaryFile(filename)) {
        return false;
      }

      const ext = path.extname(filename).toLowerCase();
      const allowedExtensions = [
        '.d',
        '.c',
        '.h',
        '.sdl',
        '.sh',
        '.json',
        '.toml',
        '.yaml',
        '.yml',
        '.build',
        '.txt',
        '.go',
        '.work',
      ];
      if (
        !allowedExtensions.includes(ext) &&
        filename !== 'Makefile' &&
        filename !== 'Cargo.toml'
      ) {
        return false;
      }

      try {
        const stats = fs.statSync(absPath);
        if (stats.size > 40 * 1024) {
          // Skip files > 40 KB
          return false;
        }
      } catch (e) {
        return false;
      }

      return true;
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

    function extractLinks(content: string): string[] {
      const links: string[] = [];
      const inlineRegex = /\[[^\]]*\]\(([^)]+)\)/g;
      let match;
      while ((match = inlineRegex.exec(content)) !== null) {
        links.push(match[1]);
      }
      const refRegex = /^\[[^\]]+\]:\s*([^\s#]+)/gm;
      while ((match = refRegex.exec(content)) !== null) {
        links.push(match[1]);
      }
      return links;
    }

    // Step 1: Scan all hand-written markdown files in docs/
    function scanMarkdownFiles(dir: string) {
      if (!fs.existsSync(dir)) return;
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (
            entry.name === '.vitepress' ||
            entry.name === 'node_modules' ||
            entry.name.startsWith('.')
          ) {
            continue;
          }
          scanMarkdownFiles(fullPath);
        } else if (
          entry.name.endsWith('.md') &&
          entry.name !== '[filepath].md'
        ) {
          const content = fs.readFileSync(fullPath, 'utf8');
          const links = extractLinks(content);
          const currentDir = path.dirname(fullPath);

          for (const link of links) {
            if (/^(https?:|mailto:|#)/.test(link)) {
              continue;
            }
            const [urlPath] = link.split('#');
            if (!urlPath) continue;

            const resolvedAbsPath = path.resolve(currentDir, urlPath);
            if (fs.existsSync(resolvedAbsPath)) {
              const relToRepo = path
                .relative(repoDir, resolvedAbsPath)
                .replace(/\\/g, '/');
              const stats = fs.statSync(resolvedAbsPath);
              if (stats.isDirectory()) {
                targetDirs.add(relToRepo);
              } else if (stats.isFile()) {
                if (relToRepo.endsWith('.md')) {
                  continue;
                }
                if (isBinaryFile(resolvedAbsPath)) {
                  continue;
                }
                // Any explicitly linked file MUST have a route generated to avoid dead links.
                targetFiles.add(relToRepo);
              }
            }
          }
        }
      }
    }

    // Step 2: Recursively expand scanned directories
    const dirsWithTargets = new Set<string>();
    const expandedDirs = new Set<string>();
    function expandDirectory(dirRelPath: string): boolean {
      if (expandedDirs.has(dirRelPath)) {
        return dirsWithTargets.has(dirRelPath);
      }
      expandedDirs.add(dirRelPath);

      const absPath = path.resolve(repoDir, dirRelPath);
      if (!fs.existsSync(absPath)) return false;

      let hasTarget = false;
      const entries = fs.readdirSync(absPath, { withFileTypes: true });
      for (const entry of entries) {
        const entryAbsPath = path.join(absPath, entry.name);
        const entryRelPath = path
          .relative(repoDir, entryAbsPath)
          .replace(/\\/g, '/');

        if (entry.isDirectory()) {
          if (
            entry.name === 'build' ||
            entry.name === 'bin' ||
            entry.name === 'obj' ||
            entry.name === '.dub' ||
            entry.name.startsWith('.')
          ) {
            continue;
          }
          const subHasTarget = expandDirectory(entryRelPath);
          if (subHasTarget) {
            targetDirs.add(entryRelPath);
            hasTarget = true;
          }
        } else {
          if (shouldProcessFile(entry.name, entryAbsPath)) {
            targetFiles.add(entryRelPath);
            hasTarget = true;
          }
        }
      }
      if (hasTarget) {
        dirsWithTargets.add(dirRelPath);
      }
      return hasTarget;
    }

    scanMarkdownFiles(docsDir);

    // Add all parent directories of targetFiles to targetDirs so they are generated (docs-only)
    for (const file of Array.from(targetFiles)) {
      const absPath = path.resolve(repoDir, file);
      const isInsideDocs = absPath.startsWith(docsDir + path.sep);
      if (!isInsideDocs) {
        continue;
      }

      let currentDir = path.dirname(absPath);
      while (currentDir !== docsDir && currentDir.startsWith(docsDir)) {
        const relToRepo = path
          .relative(repoDir, currentDir)
          .replace(/\\/g, '/');
        targetDirs.add(relToRepo);
        currentDir = path.dirname(currentDir);
      }
    }

    for (const dir of Array.from(targetDirs)) {
      const hasTarget = expandDirectory(dir);
      if (!hasTarget) {
        targetDirs.delete(dir);
      }
    }

    const generatedPaths = new Set<string>();
    for (const dir of Array.from(targetDirs)) {
      const isInsideDocs = path
        .resolve(repoDir, dir)
        .startsWith(docsDir + path.sep);
      const docsRelPath = isInsideDocs
        ? path.relative(docsDir, path.resolve(repoDir, dir)).replace(/\\/g, '/')
        : dir;
      generatedPaths.add(`${docsRelPath}/index`);
    }
    for (const file of Array.from(targetFiles)) {
      const isInsideDocs = path
        .resolve(repoDir, file)
        .startsWith(docsDir + path.sep);
      const docsRelPath = isInsideDocs
        ? path
            .relative(docsDir, path.resolve(repoDir, file))
            .replace(/\\/g, '/')
        : file;
      generatedPaths.add(docsRelPath);
    }

    // Helper for breadcrumbs
    function getBreadcrumbs(
      docsRelPath: string,
      isInsideDocs: boolean,
    ): string {
      const segments = docsRelPath.split('/');
      const breadcrumbSegments: any[] = [];

      // Home segment
      breadcrumbSegments.push({
        text: 'Home',
        link: '/',
        copyText: isInsideDocs ? 'docs' : '',
        gitHubUrl: isInsideDocs
          ? 'https://github.com/PetarKirov/sparkles/tree/main/docs'
          : 'https://github.com/PetarKirov/sparkles/tree/main/',
      });

      let accumulatedPath = '';
      const prefix = isInsideDocs ? 'docs/' : '';

      for (let i = 0; i < segments.length; i++) {
        const segment = segments[i];
        if (!segment) continue;

        accumulatedPath = accumulatedPath
          ? `${accumulatedPath}/${segment}`
          : segment;

        const isLast = i === segments.length - 1;
        let link: string | null = null;

        if (!isLast) {
          const hasIndexPage =
            fs.existsSync(path.resolve(docsDir, accumulatedPath, 'index.md')) ||
            generatedPaths.has(`${accumulatedPath}/index`);

          if (hasIndexPage) {
            link = `/${accumulatedPath}/`;
          }
        }

        const targetPath = `${prefix}${accumulatedPath}`;
        const absSegmentPath = path.resolve(repoDir, targetPath);
        let gitHubUrl = '';
        if (fs.existsSync(absSegmentPath)) {
          const stats = fs.statSync(absSegmentPath);
          if (stats.isFile()) {
            gitHubUrl = `https://github.com/PetarKirov/sparkles/edit/main/${targetPath}`;
          } else {
            gitHubUrl = `https://github.com/PetarKirov/sparkles/tree/main/${targetPath}`;
          }
        } else {
          // Fallback or dynamically generated page
          const dirPath = path.dirname(targetPath);
          gitHubUrl = `https://github.com/PetarKirov/sparkles/tree/main/${dirPath}`;
        }

        breadcrumbSegments.push({
          text: segment,
          link: link,
          copyText: targetPath,
          gitHubUrl: gitHubUrl,
        });
      }

      const segmentsJson = JSON.stringify(breadcrumbSegments)
        .replace(/'/g, '&#39;')
        .replace(/"/g, '&quot;');

      return `<Breadcrumbs :segments="${segmentsJson}" />`;
    }

    // Step 3: Build directory index routes
    for (const dir of Array.from(targetDirs)) {
      const absPath = path.resolve(repoDir, dir);
      if (fs.existsSync(path.resolve(absPath, 'index.md'))) {
        continue;
      }
      const isInsideDocs = absPath.startsWith(docsDir + path.sep);
      const docsRelPath = isInsideDocs
        ? path.relative(docsDir, absPath).replace(/\\/g, '/')
        : dir;

      const children = fs.readdirSync(absPath, { withFileTypes: true });
      const folderLinks: string[] = [];
      const fileLinks: string[] = [];

      for (const child of children) {
        if (child.name.startsWith('.') || child.name === 'index.md') {
          continue;
        }
        const childAbsPath = path.join(absPath, child.name);
        const childRelPath = path
          .relative(repoDir, childAbsPath)
          .replace(/\\/g, '/');

        if (child.isDirectory()) {
          if (
            child.name === 'build' ||
            child.name === 'bin' ||
            child.name === 'obj' ||
            child.name === '.dub'
          ) {
            continue;
          }
          if (targetDirs.has(childRelPath)) {
            folderLinks.push(`- [${child.name}/](./${child.name}/)`);
          }
        } else {
          if (isBinaryFile(child.name) || child.name.endsWith('.md')) {
            continue;
          }
          if (targetFiles.has(childRelPath)) {
            fileLinks.push(`- [${child.name}](./${child.name})`);
          }
        }
      }

      const breadcrumbTrail = getBreadcrumbs(
        `${docsRelPath}/index`,
        isInsideDocs,
      );
      const content = [
        breadcrumbTrail,
        '',
        `# Directory: ${path.basename(dir)}`,
        '',
        folderLinks.length > 0
          ? '## Folders\n' + folderLinks.join('\n') + '\n'
          : '',
        fileLinks.length > 0 ? '## Files\n' + fileLinks.join('\n') + '\n' : '',
      ]
        .filter(x => x !== '')
        .join('\n');

      routes.push({
        params: { filepath: `${docsRelPath}/index` },
        content,
        frontmatter: { layout: 'page', aside: false },
      });
    }

    // Step 4: Build file routes
    for (const file of Array.from(targetFiles)) {
      const absPath = path.resolve(repoDir, file);
      const isInsideDocs = absPath.startsWith(docsDir + path.sep);
      const docsRelPath = isInsideDocs
        ? path.relative(docsDir, absPath).replace(/\\/g, '/')
        : file;

      const name = path.basename(file);
      const lang = getLanguage(name);
      const breadcrumbTrail = getBreadcrumbs(docsRelPath, isInsideDocs);

      const content = [
        breadcrumbTrail,
        '',
        `# ${name}`,
        '',
        '<div class="source-code-listing">',
        '',
        isInsideDocs
          ? `<<< @/${docsRelPath}${lang ? '{' + lang + '}' : ''}`
          : `<<< @/../${file}${lang ? '{' + lang + '}' : ''}`,
        '',
        '</div>',
      ].join('\n');

      routes.push({
        params: { filepath: docsRelPath },
        content,
        frontmatter: { layout: 'page', aside: false },
      });
    }

    return routes;
  },
};
