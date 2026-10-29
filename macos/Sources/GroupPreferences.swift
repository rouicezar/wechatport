import SwiftUI

struct GroupPreferencesPanel: View {
    @ObservedObject var archive: ArchiveModel
    @ObservedObject var brief: BriefModel
    @State private var groupID = ""
    @State private var name = ""
    @State private var preference = GroupPreference()
    @State private var status = ""
    @State private var loadedGroupID = ""
    var body: some View {
        GroupBox("群偏好") {
            VStack(alignment:.leading,spacing:14) {
                Picker("群",selection:$groupID) {
                    Text("请选择群").tag("")
                    ForEach(archive.groups) { Text($0.name + " · " + $0.id.prefix(6)).tag($0.id) }
                }
                if !groupID.isEmpty {
                    TextField("群显示名",text:$name).textFieldStyle(.roundedBorder)
                    Picker("默认模板",selection:$preference.templateID) { ForEach(brief.templates) { Text($0.name).tag($0.id) } }
                    TextField("本人在群里的别名（可选）",text:$preference.aliases).textFieldStyle(.roundedBorder)
                    TextField("关注点（可选）",text:$preference.focus).textFieldStyle(.roundedBorder)
                    Button("保存",systemImage:"checkmark") {
                        let target = groupID; let savedName = name; let savedPreference = preference
                        Task {
                            do { try await archive.savePreference(groupID:target,name:savedName,preference:savedPreference); if groupID == target { status = "已保存" } }
                            catch { status = error.localizedDescription }
                        }
                    }.disabled(loadedGroupID != groupID || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
        }.onChange(of:groupID) { _,value in
            name = archive.groups.first(where:{$0.id == value})?.name ?? ""
            loadedGroupID = ""
            Task {
                let settings = (try? await archive.preference(groupID:value)) ?? GroupPreference()
                guard groupID == value else { return }; preference = settings; loadedGroupID = value; status = ""
            }
        }
    }
}
