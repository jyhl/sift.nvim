describe('sift.nvim', function()
  local backend = require('sift.backend')
  local config = require('sift.config')
  local diff = require('sift.diff')
  local fs = require('sift.fs')
  local git = require('sift.git')
  local hunk_util = require('sift.diff.hunk')
  local prompt = require('sift.prompt')
  local review = require('sift.review')
  local reject = require('sift.review.reject')
  local session_module = require('sift.session')
  local state = require('sift.state')
  local tracker = require('sift.review.tracker')
  local ui_panel = require('sift.ui.panel')
  local unpack_fn = table.unpack or unpack

  local fixture_root = vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2):match('(.+)/') .. 'fixtures/sample-repo')

  local tempdirs = {}

  local function wait_for(predicate, message)
    assert(vim.wait(5000, predicate, 20), message or 'timed out')
  end

  local function await(run)
    local done = false
    local result = nil

    run(function(...)
      result = { ... }
      done = true
    end)

    wait_for(function()
      return done
    end)

    return unpack_fn(result or {})
  end

  local function system(args, cwd)
    local cmd = vim.deepcopy(args)

    if cwd and args[1] == 'git' then
      table.insert(cmd, 2, '-C')
      table.insert(cmd, 3, cwd)
    end

    local output = vim.fn.system(cmd)
    local code = vim.v.shell_error

    assert.are.equal(0, code, output)
  end

  local function copy_fixture_tree(src, dst)
    vim.fn.mkdir(dst, 'p')

    for _, path in ipairs(vim.fn.glob(src .. '/**/*', true, true)) do
      if vim.fn.isdirectory(path) == 0 then
        local relpath = path:sub(#src + 2)
        local target = dst .. '/' .. relpath

        vim.fn.mkdir(vim.fs.dirname(target), 'p')
        vim.fn.writefile(vim.fn.readfile(path), target)
      end
    end
  end

  local function create_workspace()
    local tmpdir = vim.fn.tempname()
    table.insert(tempdirs, tmpdir)
    copy_fixture_tree(fixture_root, tmpdir)

    system({ 'git', 'init', '-q' }, tmpdir)
    system({ 'git', 'config', 'user.email', 'sift@example.com' }, tmpdir)
    system({ 'git', 'config', 'user.name', 'sift' }, tmpdir)
    system({ 'git', 'add', '.' }, tmpdir)
    system({ 'git', 'commit', '-q', '-m', 'fixture' }, tmpdir)

    return tmpdir
  end

  local function create_repo()
    local tmpdir = create_workspace()
    local repo_root = fs.realpath(tmpdir)

    local session = {
      id = 'test-' .. tostring(math.random(100000, 999999)),
      repo_root = repo_root,
      transcript = {},
      status = 'idle',
    }

    local err, baseline = await(function(done)
      git.create_baseline(repo_root, session.id, done)
    end)

    assert.is_nil(err)
    session.baseline_ref = baseline.ref
    session.baseline_commit = baseline.commit

    state.set_session(repo_root, session)

    return session, tmpdir
  end

  local function destroy_repo(session, tmpdir)
    if session and session.baseline_ref then
      local err = await(function(done)
        git.delete_ref(session.repo_root, session.baseline_ref, done)
      end)

      assert.is_nil(err)
    end

    if session then
      state.remove_session(session.repo_root)
    end

    if tmpdir then
      vim.fn.delete(tmpdir, 'rf')
    end
  end

  local function refresh(session)
    local err, review_state = await(function(done)
      review.refresh(session, done)
    end)

    assert.is_nil(err)
    return review_state
  end

  local function ref_exists(repo_root, ref_name)
    vim.fn.system({
      'git',
      '-C',
      repo_root,
      'rev-parse',
      '--verify',
      '--quiet',
      ref_name,
    })

    return vim.v.shell_error == 0
  end

  local function write_lines(path, lines)
    vim.fn.writefile(lines, path)
  end

  local function read_lines(path)
    return vim.fn.readfile(path)
  end

  local function panel_hunk_label(hunk)
    local anchor = hunk_util.anchor(hunk)
    local finish = hunk_util.finish(hunk)
    local location = anchor == finish and ('line ' .. anchor) or string.format('lines %d-%d', anchor, finish)
    local detail = hunk.context ~= '' and hunk.context or (hunk.type or 'change')
    return string.format('    %s  %s', location, detail)
  end

  local current_session = nil
  local current_tmpdir = nil
  local original_cwd = nil

  before_each(function()
    config.setup({
      logging = {
        notify = false,
      },
    })
    review.setup()
  end)

  before_each(function()
    package.loaded.sift = nil
    original_cwd = vim.loop.cwd()
  end)

  after_each(function()
    destroy_repo(current_session, current_tmpdir)
    current_session = nil
    current_tmpdir = nil

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end

    if original_cwd and fs.realpath(vim.loop.cwd()) ~= fs.realpath(original_cwd) then
      vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))
    end
  end)

  it('loads the public module', function()
    local sift = require('sift')

    assert.is_table(sift)
    assert.is_function(sift.setup)
    assert.is_function(sift.start)
    assert.is_function(sift.stop)
    assert.is_function(sift.prompt)
  end)

  it('parses unified diffs without treating trailing blank stdout lines as hunk content', function()
    local files = diff.parse({
      'diff --git a/other.txt b/other.txt',
      'index 7a28df3..3cc64f7 100644',
      '--- a/other.txt',
      '+++ b/other.txt',
      '@@ -1,4 +1,4 @@',
      ' alpha',
      '-beta',
      '+BETA',
      ' gamma',
      ' delta',
      '',
    })

    assert.are.equal(1, #files)
    assert.are.equal(1, #files[1].hunks)
    assert.are.same({
      ' alpha',
      '-beta',
      '+BETA',
      ' gamma',
      ' delta',
    }, files[1].hunks[1].lines)
  end)

  it('ignores deleting an already-missing sift baseline ref', function()
    local session_obj, tmpdir = create_repo()
    current_session = session_obj
    current_tmpdir = tmpdir

    local err = await(function(done)
      git.delete_ref(session_obj.repo_root, session_obj.baseline_ref, done)
    end)

    assert.is_nil(err)
    session_obj.baseline_ref = current_session.baseline_ref

    err = await(function(done)
      git.delete_ref(session_obj.repo_root, session_obj.baseline_ref, done)
    end)

    assert.is_nil(err)
  end)

  it('cleans up baseline refs on VimLeavePre', function()
    local session_obj, tmpdir = create_repo()
    current_session = session_obj
    current_tmpdir = tmpdir

    session_module.setup()
    vim.api.nvim_exec_autocmds('VimLeavePre', {})

    local output = vim.fn.system({
      'git',
      '-C',
      session_obj.repo_root,
      'rev-parse',
      '--verify',
      '--quiet',
      session_obj.baseline_ref,
    })

    assert.are.equal(1, vim.v.shell_error, output)
    session_obj.baseline_ref = nil
  end)

  it('starts and stops a session from the current repository', function()
    local tmpdir = create_workspace()
    current_tmpdir = tmpdir

    vim.cmd('enew')
    vim.cmd('cd ' .. vim.fn.fnameescape(tmpdir))

    local err, started = await(function(done)
      session_module.start(done)
    end)

    assert.is_nil(err)
    assert.are.equal(fs.realpath(tmpdir), started.repo_root)
    assert.is_truthy(started.baseline_ref)
    assert.is_true(ref_exists(tmpdir, started.baseline_ref))
    assert.are.equal(0, tracker.get(started).counts.hunks)

    current_session = started

    local stop_err = await(function(done)
      session_module.stop(done)
    end)

    assert.is_nil(stop_err)
    assert.is_nil(state.get_session(started.repo_root))
    assert.is_false(ref_exists(tmpdir, started.baseline_ref))
  end)

  it('opens a right-side panel and starts a session when toggled without one', function()
    local tmpdir = create_workspace()
    current_tmpdir = tmpdir

    vim.cmd('edit ' .. vim.fn.fnameescape(tmpdir .. '/notes.txt'))

    local err, started = await(function(done)
      session_module.toggle_panel(done)
    end)

    assert.is_nil(err)
    current_session = started
    assert.are.equal(fs.realpath(tmpdir), started.repo_root)
    assert.are.equal('sift://panel/' .. started.id, vim.api.nvim_buf_get_name(0))
    assert.are.equal(config.get().panel.width, vim.api.nvim_win_get_width(0))
    assert.is_not_nil(started.baseline_ref)
  end)

  it('uses a dirty tracked file as the session baseline when starting', function()
    local tmpdir = create_workspace()
    current_tmpdir = tmpdir
    local notes = tmpdir .. '/notes.txt'

    write_lines(notes, {
      'line 1',
      'line 2 dirty before start',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })

    vim.cmd('enew')
    vim.cmd('cd ' .. vim.fn.fnameescape(tmpdir))

    local err, started = await(function(done)
      session_module.start(done)
    end)

    assert.is_nil(err)
    current_session = started
    assert.are.equal(0, tracker.get(started).counts.hunks)

    write_lines(notes, {
      'line 1',
      'line 2 dirty before start',
      'line 3 changed after start',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })

    local refresh_err, review_state = await(function(done)
      session_module.refresh(done)
    end)

    assert.is_nil(refresh_err)
    assert.are.equal(1, review_state.counts.files)
    assert.are.equal(1, review_state.counts.hunks)
    assert.are.equal('notes.txt', review_state.hunk_list[1].path)
  end)

  it('resolves and completes @file references against tracked repo files', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local matches, err = prompt.complete_paths(session, 'not')

    assert.is_nil(err)
    assert.is_true(vim.tbl_contains(matches, 'notes.txt'))

    local path, resolve_err = prompt.resolve_reference(session, 'notes.txt')

    assert.is_nil(resolve_err)
    assert.are.equal('notes.txt', path)

    local expanded, referenced, expand_err = prompt.expand(session, 'review @notes.txt')

    assert.is_nil(expand_err)
    assert.are.same({ 'notes.txt' }, referenced)
    assert.matches('Referenced project files:', expanded, 1, true)
    assert.matches('--- FILE: notes.txt ---', expanded, 1, true)
    assert.matches('line 1', expanded, 1, true)
  end)

  it('round-trips multi-line panel prompt text through render', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    ui_panel.open(session, { focus_prompt = false })
    ui_panel.set_prompt(session, 'first line\nsecond line')

    assert.are.equal('first line\nsecond line', ui_panel.get_prompt(session))
  end)

  it('toggles and jumps referenced files from the panel transcript', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    ui_panel.open(session, { focus_prompt = false })
    ui_panel.append_entry(session, 'user', 'review @notes.txt')
    ui_panel.append_references(session, { 'notes.txt' }, '--- FILE: notes.txt ---\nline 1')

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local ref_lnum = nil

    for index, line in ipairs(lines) do
      if line:find('references: 1 file', 1, true) then
        ref_lnum = index
        break
      end
    end

    assert.is_not_nil(ref_lnum)
    vim.api.nvim_win_set_cursor(0, { ref_lnum, 0 })
    ui_panel.toggle_at_cursor(session)

    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local file_lnum = nil

    for index, line in ipairs(lines) do
      if line == '    @notes.txt' then
        file_lnum = index
        break
      end
    end

    assert.is_not_nil(file_lnum)
    vim.api.nvim_win_set_cursor(0, { file_lnum, 0 })
    assert.is_true(ui_panel.jump_at_cursor(session))
    assert.are.equal(fs.realpath(notes), fs.realpath(vim.api.nvim_buf_get_name(0)))
  end)

  it('renders pending review entries in the panel and jumps to files and hunks from them', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local other = tmpdir .. '/other.txt'

    write_lines(notes, {
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    })
    write_lines(other, {
      'alpha',
      'BETA',
      'gamma',
      'delta',
    })

    refresh(session)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    ui_panel.open(session, { focus_prompt = false })

    local target_hunk = tracker.file_hunks(session, 'notes.txt')[2]
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local other_lnum = nil
    local notes_hunk_lnum = nil

    for index, line in ipairs(lines) do
      if line == '  other.txt (1 hunk)' then
        other_lnum = index
      elseif line == panel_hunk_label(target_hunk) then
        notes_hunk_lnum = index
      end
    end

    assert.is_not_nil(other_lnum)
    assert.is_not_nil(notes_hunk_lnum)

    vim.api.nvim_win_set_cursor(0, { other_lnum, 0 })
    assert.is_true(ui_panel.jump_at_cursor(session))
    assert.are.equal(fs.realpath(other), fs.realpath(vim.api.nvim_buf_get_name(0)))

    vim.api.nvim_set_current_win(session.panel.winid)
    vim.api.nvim_win_set_cursor(0, { notes_hunk_lnum, 0 })
    assert.is_true(ui_panel.jump_at_cursor(session))
    assert.are.equal(fs.realpath(notes), fs.realpath(vim.api.nvim_buf_get_name(0)))
    assert.are.equal(hunk_util.anchor(target_hunk), vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('keeps focus in the panel and reports an error when a jump action fails', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local other = tmpdir .. '/other.txt'

    write_lines(notes, {
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })
    write_lines(other, {
      'alpha',
      'BETA',
      'gamma',
      'delta',
    })

    refresh(session)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    ui_panel.open(session, { focus_prompt = false })
    session.panel_open_file = function()
      return nil, 'panel jump failed'
    end

    local other_lnum = nil
    for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if line == '  other.txt (1 hunk)' then
        other_lnum = index
        break
      end
    end

    assert.is_not_nil(other_lnum)
    vim.api.nvim_win_set_cursor(0, { other_lnum, 0 })
    assert.is_false(ui_panel.jump_at_cursor(session))
    assert.are.equal('sift://panel/' .. session.id, vim.api.nvim_buf_get_name(0))
    assert.are.equal('error', session.transcript[#session.transcript].kind)
    assert.are.equal('panel jump failed', session.transcript[#session.transcript].text)
  end)

  it('accepts a hunk without changing workspace text', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'

    write_lines(notes, {
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    })

    local review_state = refresh(session)
    assert.are.equal(1, review_state.counts.files)
    assert.are.equal(2, review_state.counts.hunks)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local accepted = review.accept_hunk(session)
    assert.are.equal(1, accepted.counts.hunks)
    assert.are.same({
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    }, read_lines(notes))
  end)

  it('keeps accepted hunks cleared across refreshes while leaving later hunks pending', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'

    write_lines(notes, {
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    })

    local review_state = refresh(session)
    assert.are.equal(2, review_state.counts.hunks)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    review.accept_hunk(session)

    assert.are.equal(1, tracker.get(session).counts.hunks)

    review_state = refresh(session)
    assert.are.equal(1, review_state.counts.hunks)
    assert.are.equal(1, #tracker.file_hunks(session, 'notes.txt'))
    assert.are.equal(10, tracker.file_hunks(session, 'notes.txt')[1].added.start)
  end)

  it('rejects a hunk by restoring baseline text for that region', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'

    write_lines(notes, {
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    })

    local review_state = refresh(session)
    assert.are.equal(2, review_state.counts.hunks)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local err = await(function(done)
      review.reject_hunk(session, function(reject_err)
        done(reject_err)
      end)
    end)

    assert.is_nil(err)
    review_state = tracker.get(session)
    assert.are.equal(1, review_state.counts.hunks)
    assert.are.same({
      'line 1',
      'line 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    }, read_lines(notes))
  end)

  it('accepts a file and reject_all only restores remaining pending files', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local other = tmpdir .. '/other.txt'

    write_lines(notes, {
      'line 1',
      'line 2 accepted',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })
    write_lines(other, {
      'alpha',
      'BETA',
      'gamma',
      'delta',
    })

    local review_state = refresh(session)
    assert.are.equal(2, review_state.counts.files)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    local accepted = review.accept_file(session)
    assert.are.equal(1, accepted.counts.files)
    assert.are.equal(1, accepted.counts.hunks)

    local err = await(function(done)
      review.reject_all(session, function(reject_err)
        done(reject_err)
      end)
    end)

    assert.is_nil(err)
    review_state = tracker.get(session)
    assert.are.equal(0, review_state.counts.hunks)
    assert.are.same({
      'line 1',
      'line 2 accepted',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    }, read_lines(notes))
    assert.are.same({
      'alpha',
      'beta',
      'gamma',
      'delta',
    }, read_lines(other))
  end)

  it('rejects the current file from the session baseline', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local other = tmpdir .. '/other.txt'

    write_lines(notes, {
      'line 1',
      'line 2',
      'line 3 updated',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })
    write_lines(other, {
      'alpha',
      'beta',
      'gamma changed',
      'delta',
    })

    refresh(session)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))

    local err = await(function(done)
      review.reject_file(session, function(reject_err)
        done(reject_err)
      end)
    end)

    assert.is_nil(err)
    assert.are.same({
      'line 1',
      'line 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    }, read_lines(notes))
    assert.are.same({
      'alpha',
      'beta',
      'gamma changed',
      'delta',
    }, read_lines(other))
    assert.are.equal(1, tracker.get(session).counts.hunks)
  end)

  it('accepts and rejects files through the public session API', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local other = tmpdir .. '/other.txt'

    write_lines(notes, {
      'line 1',
      'line 2 accepted',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })
    write_lines(other, {
      'alpha',
      'beta',
      'gamma rejected',
      'delta',
    })

    refresh(session)

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    local accept_err, accept_state = await(function(done)
      session_module.accept_file(done)
    end)

    assert.is_nil(accept_err)
    assert.are.equal(1, accept_state.counts.files)
    assert.are.equal(1, accept_state.counts.hunks)

    vim.cmd('edit ' .. vim.fn.fnameescape(other))
    local reject_err, reject_state = await(function(done)
      session_module.reject_file(done)
    end)

    assert.is_nil(reject_err)
    assert.are.equal(0, reject_state.counts.files)
    assert.are.equal(0, reject_state.counts.hunks)
    assert.are.same({
      'line 1',
      'line 2 accepted',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    }, read_lines(notes))
    assert.are.same({
      'alpha',
      'beta',
      'gamma',
      'delta',
    }, read_lines(other))
  end)

  it('accepts all pending hunks', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    write_lines(tmpdir .. '/notes.txt', {
      'line 1',
      'line 2 changed',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })
    write_lines(tmpdir .. '/other.txt', {
      'alpha',
      'beta',
      'gamma changed',
      'delta',
    })

    refresh(session)
    local review_state = review.accept_all(session)

    assert.are.equal(0, review_state.counts.files)
    assert.are.equal(0, review_state.counts.hunks)
  end)

  it('accepts all pending hunks through the public session API', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local other = tmpdir .. '/other.txt'

    write_lines(notes, {
      'line 1',
      'line 2 changed',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })
    write_lines(other, {
      'alpha',
      'beta',
      'gamma changed',
      'delta',
    })

    refresh(session)
    vim.cmd('edit ' .. vim.fn.fnameescape(notes))

    local err, review_state = await(function(done)
      session_module.accept_all(done)
    end)

    assert.is_nil(err)
    assert.are.equal(0, review_state.counts.files)
    assert.are.equal(0, review_state.counts.hunks)
    assert.are.same({
      'line 1',
      'line 2 changed',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    }, read_lines(notes))
    assert.are.same({
      'alpha',
      'beta',
      'gamma changed',
      'delta',
    }, read_lines(other))
  end)

  it('rejects all pending hunks through the public session API', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local other = tmpdir .. '/other.txt'

    write_lines(notes, {
      'line 1',
      'line 2 changed',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })
    write_lines(other, {
      'alpha',
      'beta',
      'gamma changed',
      'delta',
    })

    refresh(session)
    vim.cmd('edit ' .. vim.fn.fnameescape(notes))

    local err, review_state = await(function(done)
      session_module.reject_all(done)
    end)

    assert.is_nil(err)
    assert.are.equal(0, review_state.counts.files)
    assert.are.equal(0, review_state.counts.hunks)
    assert.are.same({
      'line 1',
      'line 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    }, read_lines(notes))
    assert.are.same({
      'alpha',
      'beta',
      'gamma',
      'delta',
    }, read_lines(other))
  end)

  it('parses add and delete hunks when unified diff counts are omitted', function()
    local files = diff.parse({
      'diff --git a/new.txt b/new.txt',
      'new file mode 100644',
      '--- /dev/null',
      '+++ b/new.txt',
      '@@ -0,0 +1 @@',
      '+hello',
      'diff --git a/gone.txt b/gone.txt',
      'deleted file mode 100644',
      '--- a/gone.txt',
      '+++ /dev/null',
      '@@ -1 +0,0 @@',
      '-bye',
    })

    assert.are.equal(2, #files)
    assert.are.equal('add', files[1].status)
    assert.are.equal('new.txt', files[1].path)
    assert.are.equal('add', files[1].hunks[1].type)
    assert.are.equal(0, files[1].hunks[1].removed.count)
    assert.are.equal(1, files[1].hunks[1].added.count)
    assert.are.equal('delete', files[2].status)
    assert.are.equal('gone.txt', files[2].path)
    assert.are.equal('delete', files[2].hunks[1].type)
    assert.are.equal(1, files[2].hunks[1].removed.count)
    assert.are.equal(0, files[2].hunks[1].added.count)
  end)

  it('refreshes review state after a Codex run completes', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local old_start = backend.start

    backend.start = function(_, prompt, handlers)
      assert.are.equal('make notes louder', prompt)

      vim.schedule(function()
        write_lines(notes, {
          'line 1',
          'LINE 2',
          'line 3',
          'line 4',
          'line 5',
          'line 6',
          'line 7',
          'line 8',
          'line 9',
          'line 10',
          'line 11',
          'line 12',
        })
        handlers.on_stdout_line('not-json output from codex')
        handlers.on_exit('0')
      end)

      return 77
    end

    vim.cmd('enew')
    vim.cmd('cd ' .. vim.fn.fnameescape(tmpdir))

    local err, prompt_session = await(function(done)
      session_module.prompt('make notes louder', function(prompt_err, finished_session)
        done(prompt_err, finished_session)
      end)
    end)

    backend.start = old_start

    assert.is_nil(err)
    assert.are.equal(session, prompt_session)
    assert.is_nil(session.run)
    assert.are.equal(1, tracker.get(session).counts.hunks)
    assert.are.equal('idle', session.status)

    local transcript_texts = {}

    for _, entry in ipairs(session.transcript) do
      table.insert(transcript_texts, entry.text)
    end

    assert.is_true(vim.tbl_contains(transcript_texts, 'Codex run completed'))
    assert.is_true(vim.tbl_contains(transcript_texts, 'not-json output from codex'))
    assert.is_true(vim.tbl_contains(transcript_texts, 'pending files after this run: notes.txt'))
  end)

  it('submits panel prompts and expands @file references before calling Codex', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local captured_prompt = nil
    local old_start = backend.start

    backend.start = function(_, prompt_text, handlers)
      captured_prompt = prompt_text

      vim.schedule(function()
        handlers.on_exit(0)
      end)

      return 91
    end

    vim.cmd('enew')
    vim.cmd('cd ' .. vim.fn.fnameescape(tmpdir))

    local err = await(function(done)
      session_module.focus_prompt(function(focus_err)
        assert.is_nil(focus_err)

        session.submit_prompt = function(text)
          session_module.prompt(text, function(prompt_err)
            done(prompt_err)
          end)
        end

        ui_panel.set_prompt(session, 'review @notes.txt')
        ui_panel.submit_prompt(session)
      end)
    end)

    backend.start = old_start

    assert.is_nil(err)
    assert.matches('Referenced project files:', captured_prompt, 1, true)
    assert.matches('--- FILE: notes.txt ---', captured_prompt, 1, true)
  end)

  it('treats malformed Codex stdout lines as plain backend output', function()
    local codex = require('sift.backend.codex')
    local util = require('sift.util')
    local old_jobstart = util.jobstart
    local seen = {
      events = {},
      stdout = {},
      stderr = {},
    }
    local exited = false

    util.jobstart = function(spec)
      vim.schedule(function()
        spec.on_stdout_line('not-json')
        spec.on_stdout_line('{"type":"turn.started"}')
        spec.on_stdout_line('{broken-json')
        spec.on_stderr_line('stderr line')
        spec.on_exit(0, 0)
      end)

      return 123
    end

    local job_id, err = codex.start({ repo_root = '/tmp' }, 'hello', {
      on_event = function(event)
        table.insert(seen.events, event)
      end,
      on_stdout_line = function(line)
        table.insert(seen.stdout, line)
      end,
      on_stderr_line = function(line)
        table.insert(seen.stderr, line)
      end,
      on_exit = function(code, signal)
        assert.are.equal(0, code)
        assert.are.equal(0, signal)
        exited = true
      end,
    })

    util.jobstart = old_jobstart

    assert.is_nil(err)
    assert.are.equal(123, job_id)

    wait_for(function()
      return exited
    end)

    assert.are.same({ 'not-json', '{broken-json' }, seen.stdout)
    assert.are.same({ 'stderr line' }, seen.stderr)
    assert.are.equal(1, #seen.events)
    assert.are.equal('turn.started', seen.events[1].type)
  end)

  it('refreshes pending hunks when gitsigns is unavailable', function()
    local session, tmpdir = create_repo()
    current_session = session
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'
    local old_loaded = package.loaded.gitsigns
    local old_preload = package.preload.gitsigns

    package.loaded.gitsigns = nil
    package.preload.gitsigns = function()
      error('gitsigns unavailable')
    end

    write_lines(notes, {
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'line 11',
      'line 12',
    })

    vim.cmd('edit ' .. vim.fn.fnameescape(notes))

    local review_state = refresh(session)
    review.next_hunk(session)

    package.preload.gitsigns = old_preload
    package.loaded.gitsigns = old_loaded

    assert.are.equal(1, review_state.counts.files)
    assert.are.equal(1, review_state.counts.hunks)
  end)

  it('rolls back reject_hunk changes when writing the file fails', function()
    local session_obj, tmpdir = create_repo()
    current_session = session_obj
    current_tmpdir = tmpdir

    local notes = tmpdir .. '/notes.txt'

    write_lines(notes, {
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    })

    refresh(session_obj)
    vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    system({ 'chmod', '0444', notes })

    local _, err = reject.hunk(session_obj, vim.api.nvim_get_current_buf(), 2)

    system({ 'chmod', '0644', notes })

    assert.is_truthy(err)
    assert.are.same({
      'line 1',
      'LINE 2',
      'line 3',
      'line 4',
      'line 5',
      'line 6',
      'line 7',
      'line 8',
      'line 9',
      'line 10',
      'LINE 11',
      'line 12',
    }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.are.equal(2, tracker.get(session_obj).counts.hunks)
  end)
end)
