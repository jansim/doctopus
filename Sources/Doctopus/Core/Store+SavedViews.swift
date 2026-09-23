import Foundation

extension Store {

    func savedViews() throws -> [SavedView] {
        try db.map("""
            SELECT id, name, icon, query, sort_key, ascending, view_mode, position
            FROM saved_views ORDER BY position, id
            """) {
            SavedView(id: $0.int(0), name: $0.string(1),
                      icon: $0.stringOrNil(2) ?? "line.3.horizontal.decrease.circle",
                      query: $0.string(3), sortKey: $0.stringOrNil(4),
                      ascending: $0.bool(5), viewMode: $0.stringOrNil(6),
                      position: $0.int(7))
        }
    }

    @discardableResult
    func upsertSavedView(_ sv: SavedView) throws -> Int64 {
        if sv.id > 0 {
            try db.run("""
                UPDATE saved_views SET name=?, icon=?, query=?, sort_key=?, ascending=?,
                                       view_mode=?, position=?
                WHERE id=?
                """, [.text(sv.name), .text(sv.icon), .text(sv.query), .text(sv.sortKey),
                      .bool(sv.ascending), .text(sv.viewMode), .int(sv.position), .int(sv.id)])
            return sv.id
        }
        return try db.run("""
            INSERT INTO saved_views(name, icon, query, sort_key, ascending, view_mode, position)
            VALUES(?,?,?,?,?,?,?)
            """, [.text(sv.name), .text(sv.icon), .text(sv.query), .text(sv.sortKey),
                  .bool(sv.ascending), .text(sv.viewMode), .int(sv.position)])
    }

    func deleteSavedView(_ id: Int64) throws {
        try db.run("DELETE FROM saved_views WHERE id=?", [.int(id)])
    }
}
