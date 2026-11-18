# Contributing to the CVR Lab website

This folder has the tools and templates to add content to the lab website.

Everything goes through a **Pull Request (PR)**: you prepare your change, open the PR,
a maintainer reviews it and merges it, and the maintainers publish the updated site.
Nobody edits `main` directly.

| In this folder | What it is for |
| --- | --- |
| `create_new_project.sh` | Creates the files of a new project from a template |
| `submit_project.sh` | Creates a branch, uploads your project and opens the PR |
| `create_new_person.sh` | Creates the profile (and photo, and personal page) of a new person |
| `submit_person.sh` | Creates a branch, uploads the person and opens the PR (also for later changes) |
| `templates/` | Templates used by the scripts (`project-template.md`, `person-template.yaml`) |

## Before you start

- Git, and a clone of the repository (`cvr-lab/cvr-lab-website`).
- Run every command **from the root of the repository**.
- To preview your changes locally you also need Hugo (extended, version 0.161.1) and Node 22:

  ```sh
  npm install     # first time only
  hugo server     # then open http://localhost:1313/
  ```

  The page reloads by itself every time you save a file.

---

## 1. Add a project

### Step 1: create the files

```sh
contributing/create_new_project.sh my_project_name
```

- The name can only contain letters, numbers, `_` and `-`. Use lowercase and a short,
  descriptive name (for example `drone_gesturecontrol`). It becomes part of the web address.
- If the project already exists, the script stops without touching anything.
- If you already have a draft in Markdown, use it as the starting point:

  ```sh
  contributing/create_new_project.sh my_project_name path/to/draft.md
  ```

This creates `content/projects/my_project_name/index.md`.

### Step 2: fill in the information

Edit `index.md`. The block between the two `---` lines is what the website uses:

```yaml
---
title: Project title
summary: Two or three sentences explaining what the project does.
date: '2026-11-10'
tags:
- Robotics
- Drones
authors:
- Jane Doe
- John Smith
links:
- type: code
  url: https://github.com/cvr-lab/my-repository
  label: Code
  icon: brands/github
---
```

- **`summary`** appears on the project card. If you do not write any text below the
  `---` block, it is also shown as the description on the project page. You only need to
  write below the block if you want a longer page.
- **`authors`**: write each name **exactly** as it appears in the person's profile
  (see [section 2.3](#23-link-people-with-their-projects-and-publications)). If the name does
  not match, the person will not be linked.
- **`tags`**: reuse existing tags whenever you can (look at other projects). Each tag is
  clickable and leads to the list of everything with that tag, so a misspelled tag creates a
  new, almost empty one.
- **`links`**: each entry has a `type` (`code`, `pdf`, `preprint`, `doi`, `dataset`, `model`,
  `slides`, `video`, `poster`, `project`, `site`, `source`), a `url` and a `label`. The `code`
  link is highlighted as the main button of the page.

### Step 3: add the image

Put a landscape image in the project folder with the name **`featured.jpg`**
(for example 1200 × 800 px):

```
content/projects/my_project_name/featured.jpg
```

It is the image of the project card. Keep it light (under about 500 KB).

### Step 4: preview

With `hugo server` running, open `http://localhost:1313/projects/my_project_name/` and
check the page, the card in `/projects/`, the links and the authors.

### Step 5: submit

```sh
contributing/submit_project.sh my_project_name
```

The script, in this order:

1. checks that you are on `main` and that the only changes in your folder are inside
   `content/projects/my_project_name/`;
2. updates `main`;
3. creates the branch `add-project-my_project_name`;
4. commits with the message `Add project: my_project_name`;
5. uploads the branch;
6. opens the Pull Request if the GitHub CLI (`gh`) is installed and logged in. Otherwise
   it prints a link: open it in the browser to create the PR by hand.

### If something fails

| Message | What to do |
| --- | --- |
| `Please switch to 'main' before submitting` | `git switch main` |
| `There are changes outside content/projects/<name>/` | Commit or discard those other changes first (`git status` shows them) |
| `Remote branch ... already exists` | You already submitted this project. Finish or close that PR first |
| `Local branch ... already exists` | Delete the old one: `git branch -D add-project-<name>` |
| `Project file not found` | Create it first with `create_new_project.sh` |
| `project already exists` (create script) | Pick another name, or edit the existing project |

---

## 2. People

### 2.1 How people work

Three things are involved, and all of them use the **slug**: the person's name in
lowercase and with dashes (`Jane Doe` becomes `jane-doe`).

| What | Where | What it does |
| --- | --- | --- |
| Profile | `data/authors/<slug>.yaml` | Name, role, short description, links and the group the person belongs to |
| Photo | `assets/media/authors/<slug>.jpg` | Photo on the card and on the profile |
| Personal page | `/authors/<slug>/` | Generated automatically; lists everything where the person is an author |

- The **card in `/people/`** is built from the profile and the group. A person appears
  only if their group is in the list of `content/people/index.md`.
- The **personal page** lists every project, publication or news item that cites the person
  in its `authors:` field. A person is "integrated" with their work simply by being written
  with the correct name in that field.

### 2.2 Add a person

**Step 1: create the files.**

```sh
contributing/create_new_person.sh "Jane Doe" -g "Grad Students" -e jane@ugr.es -p ~/photo.jpg
```

Everything except the name is optional (run it without options to see them all):

| Option | Meaning |
| --- | --- |
| `-g`, `--group` | Group in `/people/` (default `Grad Students`). It must be one of the groups listed in `content/people/index.md`: the script warns you if it is not |
| `-r`, `--role` | Role shown on the card |
| `-e`, `--email` | Email |
| `-b`, `--bio` | Short description (the card shows two lines) |
| `-w`, `--weight` | Order inside the group (lower goes first, default 100) |
| `-p`, `--photo` | Photo to copy (jpg, jpeg, png or webp, square if possible) |
| `--given`, `--family` | Given name and family name. By default the family name is the last word; with two surnames use `--family "Lopez Perez"` |
| `--from FILE` | Start from your own draft of the profile instead of the template. It cannot be the profile of another person (its role, links and group would be copied) |
| `--no-page` | Do not create the personal page (see below) |

The script creates, using the slug (`Jane Doe` becomes `jane-doe`):

- `data/authors/jane-doe.yaml`: the profile, from `templates/person-template.yaml`.
  Whatever you did not provide is left as `TODO`;
- `assets/media/authors/jane-doe.jpg`: the photo, if you gave one;
- `content/authors/jane-doe/_index.md`: a small file that gives the person a personal page
  even if no project, publication or news item mentions them yet. Without it the card
  would link to a page that does not exist (a 404 error).

It also compares the fields of the new profile with an existing one and warns if they differ.
If the name has accents, it tells you the exact slug it will use: write the name **exactly
like that** in `authors:`.

**Step 2: complete the profile.** Open `data/authors/jane-doe.yaml` and replace every
`TODO` (role, biography, email). Add the other links (Google Scholar, ORCID, GitHub...)
by uncommenting the examples in the file. The fields are:

| Field | What it is |
| --- | --- |
| `schema`, `slug` | Fixed by the script. Do not change them |
| `name.display` | The name as written in `authors:` of projects, publications and news |
| `name.given`, `name.family` | Given name and family name (the family name is used to sort people) |
| `role` | Shown in bold on the card |
| `bio` | Biography. The card shows the first two lines, the personal page shows all of it |
| `affiliations` | The first one is shown on the card |
| `links` | One entry per icon or button (`at-symbol` for email, `academicons/google-scholar`, `brands/github`...) |
| `interests`, `education` | Optional. Uncomment the examples in the file if you want them |
| `user_groups` | Group of `/people/` (see section 2.1) |
| `weight` | Order inside the group |

**Step 3: photo.** If you did not pass `-p`, copy it to `assets/media/authors/jane-doe.jpg`
(square, at least 460 x 460 px). Without a photo, a generic icon is shown.

**Step 4: preview** with `hugo server`:

- `http://localhost:1313/people/` shows the card in the right group;
- clicking the card opens `http://localhost:1313/authors/jane-doe/` without errors.

If the personal page gives a 404 even though `_index.md` exists, the person needs to be
cited somewhere (for example in a welcome news item) until the page is generated. Tell a
maintainer.

**Step 5: submit.**

```sh
contributing/submit_person.sh jane-doe
```

It does the same as the project script, in this order: it checks that you are on `main`, that
the profile has no `TODO` left, that the photo exists (use `--no-photo` to submit without
one) and that the only changes are this person's files; then it updates `main`, creates the
branch `add-person-jane-doe`, commits (`Add person: Jane Doe`), uploads it and opens the
Pull Request (or prints the link if the GitHub CLI is not available).

### 2.3 Link people with their projects and publications

Nothing needs to be configured on the person: the link is made **from the project or
publication**, by writing the name in its `authors:` field exactly as in the profile.

```yaml
authors:
- Jane Doe
```

- Same spelling, same accents, same capital letters as in the profile. `Jane Doe` and
  `Jane  Doe` or `jane doe` are different names for the site.
- Do the same in news items if you want the person to appear as their author.
- Once the name is correct, the project or publication shows up automatically in the
  person's page (`/authors/<slug>/`) and the author name becomes a link.

For **automatic publication import**, also add the person to `scripts/publications/sources.yaml`
with their ORCID, using the same name as in the profile. From then on their new papers are
proposed every week in a PR for review. We have to include the new person in `scripts/publications/sources.yaml`
after we launch `submit_person.sh`. Ideally, this action should be done by a maintainer,
who should have a better understanding of the environment and know how to verify that the 
jobs are being imported correctly.

**Check:** open `/authors/<slug>/` and confirm that the expected projects and publications are
listed. If one is missing, its `authors:` name does not match the profile.

### 2.4 When someone leaves the lab (hide, do not delete)

The idea is to remove the person from `/people/` while keeping everything else: their
name and link in old projects and publications, and their personal page.

1. In `data/authors/<slug>.yaml`, change `user_groups` to a group that is **not** in the list of
   `content/people/index.md`. By convention we use `Hidden`:

   ```yaml
   user_groups:
     - Hidden
   ```

2. **Do not** delete the profile file, the photo or `content/authors/<slug>/`.
3. If the person should stop appearing in the automatic publication import, remove their entry
   from `scripts/publications/sources.yaml`.
4. Check with `hugo server`: the card is gone from `/people/`, but
   `/authors/<slug>/` still loads and old projects still link to it.
5. Submit the change. The `--update` option is for people who already exist:

   ```sh
   contributing/submit_person.sh jane-doe --update
   ```

   It uses the branch `update-person-jane-doe` and the commit message `Update person: Jane Doe`.
   The same command is used to change any other data of the profile (role, links, photo).

Notes:

- To bring someone back, put their group back and submit it with `--update`.
- Deleting the profile instead would leave their name as plain text, without photo or link,
  in every old project and publication.

### 2.5 Common problems

| Problem | Likely cause |
| --- | --- |
| The card does not appear in `/people/` | `user_groups` is missing, misspelled, or not listed in `content/people/index.md` |
| The card appears but the link gives a 404 | The person is not cited anywhere and `content/authors/<slug>/_index.md` is missing |
| The author's name in a project is not a link | The name does not match the profile exactly |
| The photo does not show | The file is not in `assets/media/authors/` or its name is not the slug |
| The person appears twice | They are in two groups of `user_groups` |

Messages of `submit_person.sh`:

| Message | What to do |
| --- | --- |
| `The profile still has TODO lines` | Complete the lines it lists |
| `No photo found ...` | Add `assets/media/authors/<slug>.jpg`, or use `--no-photo` |
| `There are changes outside this person's files` | Commit or discard the other changes first (`git status`) |
| `already exists in the repository. Use --update` | The person is already published: add `--update` to change them |
| `is not in the repository yet. Submit it without --update` | It is a new person: run it without `--update` |
| `Remote branch ... already exists` | A previous submission is still open. Finish or close that PR first |

---

## 3. Where things live

| What | Where |
| --- | --- |
| Projects | `content/projects/<name>/index.md` (+ `featured.jpg`) |
| Publications | `content/publications/<key>/index.md` (+ `cite.bib`) |
| News | `content/blog/<date-name>/index.md` |
| People profiles | `data/authors/<slug>.yaml` |
| People photos | `assets/media/authors/<slug>.jpg` |
| People page (groups and order) | `content/people/index.md` |
| Personal pages without content | `content/authors/<slug>/_index.md` |
| Automatic publication import | `scripts/publications/sources.yaml` |