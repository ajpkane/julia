# default locations: local package repo, remote metadata repo

const PKG_DEFAULT_DIR = string(ENV["HOME"], "/.julia")
const PKG_DEFAULT_META = "git://github.com/StefanKarpinski/jul-METADATA.git"
const PKG_GITHUB_URL_RE = r"^(?:git@|git://|https://(?:[\w\.\+\-]+@)?)github.com[:/](.*)$"i

# some utility functions for working with git repos

git_dir() = chomp(readall(`git rev-parse --git-dir`))
git_dirty() = !success(`git diff --quiet HEAD`)
git_staged() = !success(`git diff --cached --quiet`)
git_unstaged() = !success(`git diff --quiet`)
git_modules(args::Cmd) = chomp(readall(`git config -f .gitmodules $args`))
git_different(verA::String, verB::String, path::String) =
    !success(`git diff --quiet $verA $verB -- $path`)

function git_each_submodule(f::Function, recursive::Bool, dir::ByteString)
    cmd = `git submodule foreach --quiet 'echo "$name\t$path\t$sha1"'`
    for line in each_line(cmd)
        name, path, sha1 = match(r"^(.*)\t(.*)\t([0-9a-f]{40})$", line).captures
        @cd dir f(name, path, sha1)
        if recursive
            @cd path git_each_submodule((n,p,s)->(@cd dir f(n,"$path/$p",s)), true, dir)
        end
    end
end
git_each_submodule(f::Function, r::Bool) = git_each_submodule(f, r, cwd())

function git_read_config(file::String)
    cfg = Dict()
    # TODO: use --null option for better handling of weird values.
    for line in each_line(`git config -f $file --get-regexp '.*'`)
        key, val = match(r"^(\S+)\s+(.*)$", line).captures
        cfg[key] = has(cfg,key) ? [cfg[key],val] : val
    end
    return cfg
end

# TODO: provide a clean way to avoid this disaster
function git_read_config_blob(blob::String)
    tmp = tmpnam()
    fh = open(tmp,"w")
    try write(fh,readall(`git cat-file blob $blob`))
    catch err
        close(fh)
        throw(err)
    end
    close(fh)
    cfg = git_read_config(tmp)
    run(`rm -f tmp`)
    return cfg
end

function git_write_config(file::String, cfg::Dict)
    tmp = tmpnam()
    for key in sort!(keys(cfg))
        val = cfg[key]
        if isa(val,Array)
            for x in val
                run(`git config -f $tmp --add $key $x`)
            end
        else
            run(`git config -f $tmp $key $val`)
        end
    end
    run(`mv -f $tmp $file`)
end

git_canonicalize_config(file::String) = git_write_config(file, git_read_config(file))

function git_config_sections(cfg::Dict)
    sections = Set{ByteString}()
    for key in keys(cfg)
        m = match(r"^(.+)\.", key)
        if m != nothing add(sections,m.captures[1]) end
    end
    sections
end

# create a new empty packge repository

function pkg_init(dir::String, meta::String)
    run(`mkdir $dir`)
    @cd dir begin
        run(`git init`)
        run(`git commit --allow-empty -m "[jul] empty package repo"`)
        pkg_install({"METADATA" => meta})
    end
end
pkg_init(dir::String) = pkg_init(dir, PKG_DEFAULT_META)
pkg_init() = pkg_init(PKG_DEFAULT_DIR)

# clone a new package repo from a URL

function pkg_clone(dir::String, url::String)
    run(`git clone $url $dir`)
    @cd dir pkg_checkout("HEAD")
end
pkg_clone(url::String) = pkg_clone(PKG_DEFAULT_DIR, url)

# checkpoint a repo, recording submodule commits as tags

function pkg_checkpoint()
    git_each_submodule((name,path,sha1)->begin
        run(`git fetch-pack -q $path HEAD`)
        run(`git tag -f submodules/$path/$(sha1[1:10]) $sha1`)
        run(`git --git-dir=$path/.git gc -q`)
        head = @cd path chomp(readall(`git rev-parse --symbolic-full-name HEAD`))
        m = match(r"^refs/heads/(.*)$", head)
        if m != nothing
            branch = m.captures[1]
            git_modules(`submodule.$name.branch $branch`)
        else
            try git_modules(`--unset submodule.$name.branch`) end
        end
    end, true)
    run(`git add .gitmodules`)
end

# checkout a particular repo version

function pkg_checkout(rev::String)
    dir = cwd()
    run(`git checkout -fq $rev`)
    run(`git submodule update --init --reference $dir --recursive`)
    run(`git ls-files --other` | `xargs rm -rf`)
    git_each_submodule((name,path,sha1)->begin
        branch = try git_modules(`submodule.$name.branch`) end
        if branch != nothing
            @cd path run(`git checkout -B $branch $sha1`)
        end
    end, true)
end
pkg_checkout() = pkg_checkout("HEAD")

# commit the current state of the repo with the given message

function pkg_commit(msg::String)
    pkg_checkpoint()
    git_canonicalize_config(".gitmodules")
    run(`git commit -m $msg`)
end

# install packages by name and, optionally, git url

function pkg_install(urls::Associative)
    names = sort!(keys(urls))
    if isempty(names) return end
    dir = cwd()
    for pkg in names
        url = urls[pkg]
        run(`git submodule add --reference $dir $url $pkg`)
    end
    pkg_checkout()
    pkg_commit("[jul] install "*join(names, ", "))
end
function pkg_install(names::AbstractVector)
    urls = Dict()
    for pkg in names
        urls[pkg] = chomp(readall(open("METADATA/$pkg/url")))
    end
    pkg_install(urls)
end
pkg_install(names::String...)      = pkg_install([names...])

# remove packages by name

function pkg_remove(names::AbstractVector)
    if isempty(names) return end
    sort!(names)
    for pkg in names
        run(`git rm --cached -- $pkg`)
        git_modules(`--remove-section submodule.$pkg`)
    end
    run(`git add .gitmodules`)
    pkg_commit("[jul] remove "*join(names, ", "))
    run(`rm -rf $names`)
end
pkg_remove(names::String...) = pkg_remove([names...])

# push & pull package repos to/from remotes

function pkg_push()
    pkg_checkpoint()
    run(`git push --tags`)
    run(`git push`)
end

function pkg_pull()
    # get remote data
    run(`git fetch --tags`)
    run(`git fetch`)

    # see how far git gets with merging
    if success(`git merge -m "[jul] pull (simple merge)" FETCH_HEAD`) return end

    # get info about local, remote and base trees
    Lh = chomp(readall(`git rev-parse --verify HEAD`))
    Rh = chomp(readall(`git rev-parse --verify FETCH_HEAD`))
    base = chomp(readall(`git merge-base $Lh $Rh`))
    Rc = git_read_config_blob("$Rh:.gitmodules")
    Rs = git_config_sections(Rc)

    # intelligently 3-way merge .gitmodules versions
    if git_different(Lh,Rh,".gitmodules")
        Lc = git_read_config_blob("$Lh:.gitmodules")
        Bc = git_read_config_blob("$base:.gitmodules")
        Ls = git_config_sections(Lc)
        Bs = git_config_sections(Bc)
        # expunge removed submodules from both sides
        for section in Bs - Ls & Rs
            path = get(Lc,"$section.path",nothing)
            if path != nothing
                run(`git rm -qrf --cached --ignore-unmatch -- $path`)
                run(`rm -rf $path`)
            end
            filter!((k,v)->!begins_with("$section.",k),Lc)
            filter!((k,v)->!begins_with("$section.",k),Rc)
        end
        # merge the remaining config key-value pairs
        cfg = Dict()
        conflicts = false
        for key in keys(merge(Lc,Rc))
            Lv = get(Lc,key,nothing)
            Rv = get(Rc,key,nothing)
            Bv = get(Bc,key,nothing)
            if Lv == Rv || Rv == Bv
                if Lv != nothing cfg[key] = Lv end
            elseif Lv == Bv
                if Rv != nothing cfg[key] = Rv end
            else # conflict!
                print(stderr_stream,
                    "\n*** WARNING ***\n\n",
                    "Module configuration conflict for $key:\n",
                    "  local value = $Lv\n",
                    "  remote value = $Rv\n",
                    "\n",
                    "Both values written to .gitmodules -- please edit and choose one.\n\n",
                )
                cfg[key] = [Lv,Rv]
                conflicts = true
            end
        end
        # write the result and stage it
        git_write_config(".gitmodules",cfg)
        if !conflicts run(`git add .gitmodules`) end
    end

    # merge submodules
    git_each_submodule((name,path,sha1)->begin
        if has(Rs,"submodule.$name") && git_different(Lh,Rh,path)
            alt = chomp(readall(`git rev-parse $Rh:$path`))
            @cd path run(`git merge --no-edit $alt`)
            run(`git add $path`)
        end
    end,false)

    # check for remaining merge conflicts
    if git_unstaged()
        unmerged = readall(`git ls-files -m` | `sort` | `uniq`)
        unmerged = replace(unmerged, r"^", "    ")
        print(stderr_stream,
            "\n*** WARNING ***\n\n",
            "You have unresolved merge conflicts in the following files:\n\n",
            unmerged,
            "\nPlease resolve these conflicts `git add` the files and commit.\n"
        )
        error("pkg_pull: merge conflicts")
    end

    run(`git commit -m "[jul] pull (complex merge)"`)
    pkg_checkout("HEAD")
    pkg_checkpoint()
end
