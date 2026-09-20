'use strict';
'require view';
'require fs';
'require dom';
'require ui';
'require tools.isongwrt as iso';

var UPLOAD_TMP = '/tmp/isongwrt-upload.json';
var NEW_SHARD = '10-user';
var MAX_BACKUPS = 10;

function btn(label, style, fn) {
	return E('button', { 'class': 'btn cbi-button cbi-button-' + style, 'click': fn }, label);
}

function row(title, field, desc) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [
			field,
			desc ? E('div', { 'class': 'cbi-value-description' }, desc) : ''
		])
	]);
}

/* Backups are reported as plain file names with the timestamp embedded by ctl
   (`<shard>-YYYYmmdd-HHMMSS.json`). An explicit mtime field, if the backend ever
   reports one, takes precedence. */
function backupName(b) {
	return (b && typeof b === 'object') ? String(b.name || '') : String(b || '');
}

function backupTime(b) {
	if (b && typeof b === 'object' && b.mtime != null && !isNaN(Number(b.mtime)))
		return Number(b.mtime);
	var m = /(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/.exec(backupName(b));
	if (!m)
		return 0;
	return Date.parse(m[1] + '-' + m[2] + '-' + m[3] + 'T' + m[4] + ':' + m[5] + ':' + m[6]) || 0;
}

function shardName(self) {
	return (self.current === '__new__') ? NEW_SHARD : self.current;
}

return view.extend({
	load: function () {
		return iso.call(['config-list']);
	},

	render: function (list) {
		var self = this;
		self.list = list || {};
		self.files = self.list.files || [];
		self.backups = self.list.backups || [];
		self.current = self.files.length ? self.files[0].name : NEW_SHARD;
		self.content = '';

		self.editor = E('textarea', {
			'class': 'cbi-input-textarea',
			'rows': '24',
			'style': 'width:100%;min-height:420px;height:62vh;font-family:monospace;' +
				'font-size:13px;line-height:1.45;box-sizing:border-box;resize:vertical',
			'spellcheck': 'false',
			'input': function (ev) { self.content = ev.target.value; }
		}, '');

		self.select = E('select', {
			'class': 'cbi-input-select',
			'change': function (ev) {
				self.current = ev.target.value;
				return self.loadContent().then(function () { self.editor.value = self.content; });
			}
		});

		self.backupBox = E('div', {});

		function paintSelect() {
			var opts = self.files.map(function (f) {
				return E('option', { 'value': f.name, 'selected': f.name === self.current ? '' : null },
					f.name + '.json（' + f.size + ' B）');
			});
			opts.push(E('option', { 'value': '__new__' }, '＋ 新建 10-user.json'));
			dom.content(self.select, opts);
		}

		/* Newest first, most recent MAX_BACKUPS entries only */
		function sortedBackups() {
			return (self.backups || []).slice().sort(function (a, b) {
				var ta = backupTime(a), tb = backupTime(b);
				if (ta !== tb)
					return tb - ta;
				return backupName(a) < backupName(b) ? 1 : -1;
			}).slice(0, MAX_BACKUPS);
		}

		function paintBackups() {
			var list = sortedBackups();
			if (!list.length) {
				dom.content(self.backupBox, E('em', {}, '暂无备份'));
				return;
			}
			dom.content(self.backupBox, E('table', { 'class': 'table' },
				list.map(function (b) {
					var name = backupName(b);
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, name),
						E('td', { 'class': 'td right' }, btn('恢复', 'apply', function () {
							return iso.busy(iso.call(['config-restore', name]), '恢复备份…').then(function (r) {
								iso.notify(r, '已恢复 ' + name);
								return self.loadContent().then(function () {
									self.editor.value = self.content;
								});
							});
						}))
					]);
				})));
		}

		self.paintSelect = paintSelect;
		self.paintBackups = paintBackups;

		paintSelect();
		paintBackups();
		self.loadContent().then(function () { self.editor.value = self.content; });

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, '配置管理'),
			E('div', { 'class': 'cbi-map-descr' },
				'The core loads every shard of this directory (sing-box -C). The panel only injects its own ' +
				'shard (90-isongwrt-api.json) and never rewrites the shards you provide — but saving or ' +
				'uploading on this page does replace the shard selected above. The previous content is kept ' +
				'as a backup first and restored automatically if validation fails.'),

			E('div', { 'class': 'cbi-section' }, [
				row('分片文件', self.select),
				row('操作', E('div', {}, [
					btn('校验并保存', 'apply', function () { return self.save(); }),
					' ',
					E('input', {
						'type': 'file', 'accept': '.json',
						'style': 'display:inline-block;vertical-align:middle',
						'change': function (ev) { return self.upload(ev); }
					})
				]), 'Uploading a file replaces the shard selected above (confirmed before overwriting).')
			]),

			E('div', { 'class': 'cbi-section' }, [ self.editor ]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '备份（最近 ' + MAX_BACKUPS + ' 条）'),
				self.backupBox
			])
		]);
	},

	loadContent: function () {
		var self = this;
		return iso.call(['config-get', shardName(self)]).then(function (r) {
			self.content = (r && r.ok) ? (r.content || '') : '';
			if (r && !r.ok) iso.notify(r, '');
		});
	},

	save: function () {
		var self = this;
		var name = shardName(self);
		if (!String(self.content || '').trim()) {
			return iso.alert('内容为空：请先在上方编辑，或选择要上传的 .json 文件', 'warning', '无法保存');
		}
		return fs.write(UPLOAD_TMP, self.content).then(function () {
			return iso.busy(iso.call(['config-save', name, UPLOAD_TMP]), '校验并保存…');
		}).then(function (r) {
			iso.notify(r, '已保存 ' + name + '.json');
			self.current = name;
			return iso.call(['config-list']).then(function (l) {
				self.files = (l && l.files) || [];
				self.backups = (l && l.backups) || [];
				/* Refresh both lists: the select (new/renamed shard) and the
				   backup table (a fresh backup was just written). */
				if (self.paintSelect) self.paintSelect();
				if (self.paintBackups) self.paintBackups();
			});
		});
	},

	upload: function (ev) {
		var self = this;
		var input = ev.target;
		var file = input.files && input.files[0];
		if (!file)
			return Promise.resolve();

		/* The upload replaces the shard currently selected in the drop-down */
		var target = shardName(self);

		return new Promise(function (resolve, reject) {
			var reader = new FileReader();
			reader.onload = function () { self.content = String(reader.result); resolve(); };
			reader.onerror = reject;
			reader.readAsText(file);
		}).then(function () {
			return new Promise(function (resolve) {
				ui.showModal('上传配置', [
					E('p', {}, '文件「' + file.name + '」的内容将写入 /etc/isongwrt/conf/' + target + '.json。'),
					E('p', {}, '现有内容会先备份，新内容校验通过后才生效；校验失败自动回退。'),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'click': function () { ui.hideModal(); resolve(false); } }, '取消'),
						' ',
						E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': function () { ui.hideModal(); resolve(true); } },
							'替换 ' + target + '.json')
					])
				]);
			});
		}).then(function (confirmed) {
			/* Allow re-selecting the same file later on */
			input.value = '';
			if (!confirmed)
				return;
			self.current = target;
			self.editor.value = self.content;
			if (self.paintSelect) self.paintSelect();
			return self.save();
		}).catch(function (e) {
			input.value = '';
			iso.alert('读取文件失败：' + ((e && e.message) || e), 'error', '上传失败');
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
