using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace PebbleAudio.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Tools_SharingScope : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "ScopeDays",
                table: "SyncPreferences",
                type: "integer",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "ScopeKind",
                table: "SyncPreferences",
                type: "text",
                nullable: false,
                // Existing rows share everything, as they did before the scope existed.
                defaultValue: "All");

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "ScopeSince",
                table: "SyncPreferences",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "ScopeSweptFor",
                table: "SyncPreferences",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "TimeZone",
                table: "SyncPreferences",
                type: "text",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "ScopeDays",
                table: "SyncPreferences");

            migrationBuilder.DropColumn(
                name: "ScopeKind",
                table: "SyncPreferences");

            migrationBuilder.DropColumn(
                name: "ScopeSince",
                table: "SyncPreferences");

            migrationBuilder.DropColumn(
                name: "ScopeSweptFor",
                table: "SyncPreferences");

            migrationBuilder.DropColumn(
                name: "TimeZone",
                table: "SyncPreferences");
        }
    }
}
