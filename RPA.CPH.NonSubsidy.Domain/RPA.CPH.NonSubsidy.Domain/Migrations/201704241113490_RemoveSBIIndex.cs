namespace RPA.CPH.NonSubsidy.Domain.Migrations
{
    using System;
    using System.Data.Entity.Migrations;
    
    public partial class RemoveSBIIndex : DbMigration
    {
        public override void Up()
        {
            DropIndex("CPH.Customers", new[] { "SBI" });
        }
        
        public override void Down()
        {
            CreateIndex("CPH.Customers", "SBI", unique: true);
        }
    }
}
