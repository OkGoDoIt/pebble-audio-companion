using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace PebbleAudio.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Gaps_AsTheAppShowsThem : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<long>(
                name: "MissingMs",
                table: "Conversations",
                type: "bigint",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "MissingMs",
                table: "Conversations");
        }
    }
}
