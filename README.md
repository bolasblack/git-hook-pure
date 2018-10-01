# git-hook-pure

You needn't bootstrap nodejs in every git hook

## Usage

```bash
yarn add git-hook-pure -D

# or

npm install git-hook-pure --save-dev
```

Then add npm script `postinstall` in `package.json`

```js
{
  // ...
  "scripts": {
    "postinstall": "./node_modules/git-hook-pure/install.sh"
  }
}
```

Then run `npm install` or `yarn`. Please backup your `.git/hooks` at first.

Will create a folder `.githooks` in the same level as `.git`. And **OVERWRITE** all git hooks in `.git/hooks`.

You can put an executable file in `.githooks/` or `.githooks/[hookName]/`.

The file under `.githooks/` will be executed in all git hook and called by `/path/to/hook-file [hook name] [...git hook arguments]`.

The file under `.githooks/[hookName]/` will be executed in specified git hook and called by `/path/to/hook-file [...git hook arguments]`.

## Work with [git lfs](https://git-lfs.github.com/)

git lfs need install some git hook, you can run `git lfs update -m` to get hook scripts and put them in `.githooks`.

For example you can put lfs script `.git/hooks/pre-push` into `.githooks/pre-push/git-lfs`.

Or you can put script

```bash
#!/bin/sh

command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting .githooks/git-lfs.\n"; exit 2; }

if [ \
  $1 = "pre-push" -o \
  $1 = "post-checkout" -o \
  $1 = "post-commit" -o \
  $1 = "post-merge" -o \
  ! t ] ; then
  git lfs "$@" || exit
fi

exit 0
```

into `.githooks/git-lfs`

## Custom [`git-hook-template.sh`](git-hook-template.sh)

Change npm script to:

```js
{
  // ...
  "scripts": {
    "postinstall": "./node_modules/git-hook-pure/install.sh /the/path/to/template/file"
  }
}
```
