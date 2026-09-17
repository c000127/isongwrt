'use strict';
'require view';
'require fs';
'require dom';
'require ui';
'require tools.isongwrt as iso';

var UPLOAD_TMP = '/tmp/isongwrt-upload.json';

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

return view.extend({
	load: function () {
		return iso.call(['config-list']);
	},

	render: function (list) {
		var self = this;
		self.list = list || {};
		self.files = self.list.files || [];
		self.backups = self.list.backups || [];
		self.current = self.files.length ? self.files[0].name : '10-user';
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

		function paintBackups() {
			if (!self.backups.length) {
				dom.content(self.backupBox, E('em', {}, '暂无备份'));
				return;
			}
			dom.content(self.backupBox, E('table', { 'class': 'table' },
				self.backups.slice(0, 10).map(function (b) {
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, b),
						E('td', { 'class': 'td right' }, btn('恢复', 'apply', function () {
							return iso.busy(iso.call(['config-restore', b]), '恢复备份…').then(function (r) {
								iso.notify(r, '已恢复 ' + b);
								return self.loadContent().then(function () {
									self.editor.value = self.content;
								});
							});
						}))
					]);
				})));
		}

		paintSelect();
		paintBackups();
		self.loadContent().then(function () { self.editor.value = self.content; });

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, '配置管理'),
			E('div', { 'class': 'cbi-map-descr' },
				'配置按分片目录加载（sing-box -C）：面板只维护 90-isongwrt-api.json，不会覆盖你的配置；保存前自动校验，失败自动回退。'),

			E('div', { 'class': 'cbi-section' }, [
				row('分片文件', self.select),
				row('操作', E('div', {}, [
					btn('校验并保存', 'apply', function () { return self.save(); }),
					' ',
					btn('创建快照', 'action', function () {
						return iso.busy(iso.call(['config-backup']), '创建快照…').then(function (r) {
							iso.notify(r, '快照已创建');
							return iso.call(['config-list']).then(function (l) {
								self.backups = (l && l.backups) || [];
								paintBackups();
							});
						});
					}),
					' ',
					E('input', {
						'type': 'file', 'accept': '.json',
						'style': 'display:inline-block;vertical-align:middle',
						'change': function (ev) { return self.upload(ev); }
					})
				])),
			]),

			E('div', { 'class': 'cbi-section' }, [ self.editor ]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '备份（最近 10 条）'),
				self.backupBox
			])
		]);
	},

	loadContent: function () {
		var self = this;
		var name = self.current === '__new__' ? '10-user' : self.current;
		return iso.call(['config-get', name]).then(function (r) {
			self.content = (r && r.ok) ? (r.content || '') : '';
			if (r && !r.ok) iso.notify(r, '');
		});
	},

	save: function () {
		var self = this;
		var name = self.current === '__new__' ? '10-user' : self.current;
		if (!String(self.content || '').trim()) {
			ui.addNotification(null, E('p', {}, '内容为空：请先在上方编辑，或选择要上传的 .json 文件'), 'warning');
			return Promise.resolve();
		}
		return fs.write(UPLOAD_TMP, self.content).then(function () {
			return iso.busy(iso.call(['config-save', name, UPLOAD_TMP]), '校验并保存…');
		}).then(function (r) {
			iso.notify(r, '已保存 ' + name + '.json');
			self.current = name;
			return iso.call(['config-list']).then(function (l) {
				self.files = (l && l.files) || [];
				self.backups = (l && l.backups) || [];
				dom.content(self.select, self.files.map(function (f) {
					return E('option', { 'value': f.name, 'selected': f.name === name ? '' : null },
						f.name + '.json（' + f.size + ' B）');
				}).concat([ E('option', { 'value': '__new__' }, '＋ 新建 10-user.json') ]));
				var box = document.querySelector('#iso-backups');
				if (box) dom.content(box, E([]));
			});
		});
	},

	upload: function (ev) {
		var self = this;
		var file = ev.target.files && ev.target.files[0];
		if (!file) return Promise.resolve();
		return new Promise(function (resolve, reject) {
			var reader = new FileReader();
			reader.onload = function () { self.content = String(reader.result); resolve(); };
			reader.onerror = reject;
			reader.readAsText(file);
		}).then(function () {
			self.current = '10-user';
			self.editor.value = self.content;
			return self.save();
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
