# git-hook-pure

You needn't bootstrap nodejs in every git hook

## Usage

Before install please backup all your `.git/hooks`.

```
yarn add git-hook-pure -D

# or

npm install git-hook-pure --save-dev
```

Will create a folder `.githooks` in the same level as `.git`. And **OVERWRITE** all git hooks in `.git/hooks`.

You can put an executable file in `.githooks/` or `.githooks/[hookName]/`.

The file under `.githooks/` will be executed in all git hook and called by `/path/to/hook-file [hook name] [...git hook arguments]`.

The file under `.githooks/[hookName]/` will be executed in specified git hook and called by `/path/to/hook-file [...git hook arguments]`.
