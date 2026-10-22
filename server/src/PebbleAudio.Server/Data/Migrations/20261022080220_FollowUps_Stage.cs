using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace PebbleAudio.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class FollowUps_Stage : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // Every follow-up stored before stages came from a phone that sent none, and reads as a reminder
            // (sync-protocol.md §2.5). The phone sends each one again with its stage after its own update.
            migrationBuilder.AddColumn<string>(
                name: "Stage",
                table: "FollowUps",
                type: "text",
                nullable: false,
                defaultValue: "Reminder");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Stage",
                table: "FollowUps");
        }
    }
}
